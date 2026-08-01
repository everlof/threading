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

The **This session** group uses the same routing to act rather than to read, and every tool in
it acts on the session the call arrived on — which is why none takes a session argument. An
agent can name and end its own conversation and no other. (The group's id is still
`session-lifecycle`: it is the key the user's disabled-groups set is stored under, so renaming
it would switch the group back on for everyone who had turned it off.)

`archive_session` is the one tool whose effect would destroy the call that asked for it —
archiving stops the agent — so it schedules rather than acts, and the archive lands after the
turn ends. The reasoning, the turn-end signal it waits on and the receipt it produces are in
[`sessions.md`](sessions.md).

`set_session_name` writes the session's `agentTitle`, the same slot the terminal title and the
transcript's `ai-title` land in — deliberately not `customTitle`, which is the user's own rename
and outranks the agent everywhere. It goes through `ProjectStore.updateAgentTitle` rather than
validating anything itself, so a tool call is held to exactly the rule the two title transports
are held to: a name that is really the agent's, the account's or the project's is refused. That
refusal is **reported**, which is why `updateAgentTitle` returns a `Bool` — an agent told its
call succeeded when the name was dropped goes on to tell the user the session was renamed while
the sidebar still says what it said before. Two further outcomes are reported as successes with
a caveat rather than as failures, because both are the user's own settled choice: a `customTitle`
already showing, and **Settings ▸ General** set to ignore agent titles at all.

The tool writes as **`.chosen`** where the two transports write as `.reported`
(`AgentTitleSource`), and a reported write cannot displace a chosen name. Without that rule the
call worked and the sidebar never showed it: a PTY-attached Claude re-asserts its own `ai-title`
through the terminal title within seconds, and the turn-end transcript read re-reads the same
record, so the rename the user had just asked for was silently put back by both. Only another
chosen name moves it — the agent calling the tool again — or the user's own rename, which
outranks everything; see the naming ladder in [`sessions.md`](sessions.md).

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

## Command contract

Built-in tool identity is closed in `MCPBuiltInTool`; its exhaustive `Family` mapping is the
single source for capability ownership. Wire names, the catalog, schemas, launch preapproval,
decoding and dispatch all derive from that identity rather than maintaining parallel string
lists. `MCPToolCatalog.catalogIssues` and `MCPToolDefinitions.definitionIssues` enforce the
load-bearing invariant: every built-in has exactly one catalog row and exactly one schema, and
the row's family agrees with the type. A broken declaration is omitted instead of being
advertised ambiguously.

The source boundary mirrors that contract. `MCPBuiltInTool.swift` owns only closed identity,
family policy and behavior annotations. `MCPTools.swift` owns the wire argument values, decoder
and schema definitions. `MCPToolCatalog.swift` owns the user-facing catalog and enablement
policy. Do not move identity back beside thousands of lines of schema literals: capability
review must remain a small exhaustive switch, while the large declarative schema catalog is
allowed to stay mechanically repetitive.

The catalog is also the runtime admission policy. `tools/list`, launch preapproval and
`MCPServer` dispatch consume the same enabled definitions. A valid built-in command whose group
is disabled still decodes for diagnostics, but `MCPToolCatalog.admits` refuses it before the
application handler runs. External extension tools use a separate open-world path and are
omitted when their names are blank, duplicate another enabled external tool, or collide with a
built-in.

`AgentCommand` is the application-layer command enum; `MCPToolCall` remains only as a
compatibility alias at the transport boundary. `AgentToolCoordinator` owns routing and common
workspace policy, while capability extensions own project, display, panel, extension-authoring,
browser-interaction and browser-inspection behavior. This keeps a new command from requiring
edits to an untyped transport switch spread across one window-controller file.

MCP behavior annotations are emitted from the typed identity as conservative promises to
clients. Unknown or state-changing behavior is not marked read-only or idempotent. Tools that
can affect resources beyond Threading's local process are marked open-world.

## Display Panel

The panel normally belongs to the selected session and presents that session's persisted tabs.
**Current Theme is the deliberate app-wide exception.** It temporarily replaces the visible tab
strip with one non-persisted inspector while leaving both per-session tab lists untouched. It is
not offered by the tab `+`, cannot be reordered or transferred, and stays visible when the user
selects another conversation. An explicit request for a session surface — Browser, Review,
Terminal, Files, Info, Attachments, Subagents, or a transferred tab — exits the inspector and
returns to the selected session's tabs. This lets a conversation remain alongside the theme being
discussed without pretending an app-wide document belongs to that conversation.

`DisplayContent.Body` is an enum, so the panel shows a `ThemedImagePreview`, a `WKWebView`, or a
native semantic scene and the `⋯` menu offers only the actions that fit — an image and a document
share almost nothing worth acting on.

`display_scene` is the generic non-HTML visualization bridge. Its value is the same bounded
`ExtensionScene` used by safe extension panels: normalized rectangles, host-owned shapes,
semantic colour roles, labels, detail, selection, and accessibility. `SemanticSceneView` renders
those marks through Threading's design system, so an external MCP can supply a treemap, heatmap,
timeline, dependency map, scatter plot, or bubble plot without introducing a domain-specific
AppKit view. The scene persists as data with its tab.

This deliberately composes with user MCP servers. For example, ArtifactKit's external stdio
server returns `structuredContent.scene`; the agent passes that value to Threading's
session-scoped `display_scene` tool. The one-off display command strips mark action identifiers:
after the tool call returns there is no process waiting for a later click. A persistent safe
extension panel can render the same scene and keep action routing because its extension process
owns a continuing panel session.

**The picture is a control.** An image the agent just produced is the thing the user most wants
to inspect, so a click, Space/Return, the trackpad's preview gesture, VoiceOver's press, and the
`⋯` menu's first item all open `MediaInspectorView` inside the current window. The app-owned
inspector begins fitted, toggles Fit/100% on double-click or Z, magnifies around the pointer,
pans, and walks the source collection with arrows, swipes, or its thumbnail rail. Space or Escape
closes and restores the source's focus. The same route serves prompt thumbnails and the session
Attachments pane, so the interaction does not depend on first finding a row and invoking a
separate system panel.

System Quick Look remains an explicit last-resort action, not the primary interaction.
`MediaInspectorDocumentView` uses PDFKit for PDF and embeds `QLPreviewView` for unfamiliar file
formats behind a named `SystemChromeBoundary`; all surrounding header, navigation, menu, rail,
zoom, focus, and surfaces remain Threading-owned and theme live. `QuickLookPresenter` still owns
the optional floating system panel's data because `QLPreviewPanel.dataSource` is non-retaining
and the panel is one system window.

These were measured rather than assumed, each having first been wrong:

- **A split item's `holdingPriority` ties with its content's hugging**, and both are 250. That
  tie is what let a dragged panel spring back on mouse-up: the divider's new width and the
  labels' preferred width were equally important, so the solver was free to prefer the labels.
  The panel is the one pane the user positions deliberately, so it holds ten points above that
  (`DisplayPaneDefaults.holdingPriority`) and the terminal keeps the default, which is also what
  makes the terminal absorb a window resize. The `NSImageView` note below is the same bug from
  the other end, fixed by flooring the content instead — one pane's worth of content cannot be
  floored one view at a time, which is why the priority moved.
- **That priority cuts both ways: anything in the pane that resists being *stretched* above 260
  is the panel's maximum width.** The divider is held where it was dragged by a constraint at the
  item's holding priority, so a view inside the pane that hugs its own content harder than that
  decides how wide the panel may be — and the panel's tab strip hugged its tabs at
  `.defaultHigh`. Measured: 228pt, whatever the window's width, with the wall moving as the page
  renamed itself, since a longer tab title bought a wider panel; a divider that could be dragged
  narrower but never wider; and the width restored on reveal quietly undone by the next layout
  pass. `ThemedTabStripView.fillsHostWidth` puts the strip below the divider — it scrolls when
  squeezed, so it never needed to hold — and pinning both its edges was *not* enough on its own,
  because the pins fix the strip's width against the pane's and leave the hugging to argue with
  whatever places the pane. The panel's own two labels are the same claim in words: the caption
  and the placeholder are both held with a `>=`, which reads as "shrink me first" and is not what
  an `NSTextField` does — their compression resistance was charging the *window* 259pt of minimum
  width for text both line-break modes were already willing to truncate, hidden until then behind
  the strip's 750 hugging winning that tie. Both now sit below `.fittingSizeCompression`.
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
- **A released constraint restores nothing.** The reveal used to activate a required width on
  the pane, lay out, and release it: traced, that is `asked 372 → with constraint 372 → released
  372 → relaid 48`. An `NSSplitViewController` positions its items with *its own* constraint at
  the item's `holdingPriority`, and that constant is still the thickness the pane had, so the
  next layout pass puts it straight back. Survivable while the item's minimum was 200 — the
  panel merely opened narrower than it was left — and fatal once `slimmestWidth` lowered the
  minimum to 48 so the panel would stop raising the *window's* minimum: two correct changes that
  were only wrong together, which is why nothing caught it. `applyDisplayPaneWidth` now moves the
  divider, so the width is the split view's own answer. **`setPosition(_:ofDividerAt:)` is not
  ignored by an `NSSplitViewController`** — the earlier note here said it was. Dividers are
  indexed among the *panes* while a split view keeps its dividers in `subviews` too, so a
  `subviews`-counted index moves the wrong one: with three panes, `subviews.count - 2` is a
  divider view.
- **The panel's remembered width is a user choice, so it goes through `PreferenceStore`.** It
  was on `UserDefaults.standard`, and the test bundle is hosted in the app: a fixture window that
  opened the panel wrote whatever width it happened to get into the developer's own preferences.
  A real machine had 48 saved there — the chrome floor, measured in an unshown window by a test
  about something else. Below `minWidth` a stored width is read as absent rather than restored,
  and a first open takes `openingFraction` of the window (floored at `defaultWidth`, capped at
  `widestOpening`) instead of one fixed number.

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

## Attachments

The Attachments tab is the session's visual history: everything that passed between the two
parties, newest first, capped at `SessionAttachmentDefaults.maximumPerSession`.

**The pane leads with its content; the slack falls below the footer, empty.** The preview used
to be the layout's one flexible element between a top-pinned list and a *bottom-pinned* footer,
so a tall panel stretched it to hundreds of points around a small picture and put the file's
name and buttons at the window's floor, a screen below the list they describe. An image now
states the preview's height (its fitted height at the pane's width, floored at
`SessionAttachmentsDefaults.minimumPreviewHeight`), the footer's floor is a
`lessThanOrEqualTo` limit rather than a home, and a gentle pull
(`SessionAttachmentsDefaults.footerPullPriority`) below the image's priority is what lets the
one kind that *should* fill the room — a PDF — still do so. A pane shorter than the picture
compresses the preview, never the footer. `SessionAttachmentsLayoutTests` pins all three.

**There are two doors into the list, and conflating them was the bug.**

| | admitted | served to a paired phone |
|---|---|---|
| **scanned** — the terminal's rendered buffer, a native conversation's finished assistant prose | inside the checkout only | yes |
| **declared** — `display_image`, `display_compare_files`, an image dropped or pasted into a prompt or a terminal | anywhere, copied in if it is not already in the checkout | yes |

The containment rule is real, but it is a rule about **what may leave over the wire**, and it was
being enforced at *admission*. Membership in this list is precisely the allowlist
`handleAttachment` resolves against — `RemoteInboundPolicy.acceptsRepositoryPath` is only a
length-and-NUL check — so without containment a single `find ~ -name '*.png'` printed in a
terminal would enumerate the user's pictures into a remotely fetchable list. That is why *scanned*
paths still may not leave the checkout: text is not a handoff, and a build log, a `cat`, or a
repository's own fixtures can name any path on disk.

A *declared* file is a different act, and applying the same rule to it protected nothing while
costing everything. `display_image` resolves the file, decodes it, size-checks it and draws it in
the panel — and then handed it to a recorder that dropped it unless it was in the checkout. Agents
work in one-off places (`$TMPDIR`, `/tmp`, a scratch directory), so in practice the one signal in
the system that unambiguously means *here is a picture* could never reach the pane. This project
is its own example: the render tests write every screenshot to `$TMPDIR/ThreadingRenders`.

**A declared file from outside the checkout is copied into
`Application Support/Threading/Attachments/<session>/<slot>/`, not referenced.** Attachments are
references everywhere else on purpose — the project file stays authoritative, so an overwrite
refreshes every preview — and this is the case that rule does not cover: nothing else owns a
temporary file, the list is persisted and outlives the turn, and reading prunes rows whose file
has gone. A reference into `$TMPDIR` therefore comes back as an empty pane once the reaper has
run, which is the vanishing-attachments bug wearing a new hat. Copying also *restores* the
property containment was really providing, more strongly than before: every file in the list now
sits somewhere the app controls, the checkout or its own store.

Two consequences worth keeping:

- **The dedupe key is the source path, not the row's own path.** A copy's path is minted per
  attachment, so matching on it would file every regenerated chart as a new row. A second
  declaration of the same source keeps the row's slot — and therefore its identity on the remote
  wire — and overwrites the bytes underneath it.
- **Custody ends where the row does.** A row evicted by the cap, and every row of a session that
  `retainOnly` forgets, takes its copied bytes with it. A *referenced* file is never deleted:
  it belongs to the checkout, and losing a row is not a reason to touch the user's file.

**Provenance is `SessionAttachment.Origin`, and it is coarser than it looks.** A terminal scan
reads the whole buffer and cannot tell a path the agent printed from one the user typed, so
everything scanned is `agent` — the session surfaced it. `user` is reserved for a deliberate
handoff through `PromptAttachment.record`: the composer's attachment strip, and a drop on the
terminal, which has to be recorded at the drop because the CLI swallows the path into `[Image #1]`
and scanning never sees it. The pane marks every row and offers All / Agent / You as a
`ThemedSegmentedControl`, hidden while the whole list is one side's. The phone shows the same mark
when the host sends one (`RemoteAttachmentDTO.origin`, optional so an older host is not guessed at).

Settings' per-agent **attachment detection** toggle gates *scanning* only. A declared handoff is
not detection, so turning it off does not hide the images you attach or the ones the agent shows
in the panel — which the empty state now says, because an empty pane that blames a setting for
something the setting does not control is worse than an empty pane.
