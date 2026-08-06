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

Grok native Chat receives the same private endpoint through ACP's `mcpServers` member on
`session/new` and `session/load`. This is per-process and per-session, so no `.mcp.json` or user
configuration is rewritten. Claude and Codex Terminal receive the same scoped server through
their launch configuration. Grok and OpenCode terminal sessions do not receive this registration:
Grok's TUI exposes only persistent MCP configuration, while OpenCode has a future path through its
local server once Threading owns and measures that lifecycle. Until those contracts exist, the
tools stay absent rather than appearing configured while calls cannot route.

One tool uses that routing as a data boundary rather than merely a destination.
`conversation_history` exists for any handoff destination with a scoped bridge and reads only the
normalised snapshot named by that destination session's id. Its argument is just an opaque page
cursor: the caller cannot supply a project, source session or filesystem path. The app resolves
lineage on the main actor, parses the snapshot off it, and returns a provider-neutral page of
visible dialogue and bounded tool context; private thinking is omitted. A `next_cursor` continues
large histories, and the response says when capture had to truncate. The tool lives in the
default-enabled **Conversation handoff** catalog group; turning that group off removes the
Continue menu because no continuation is then admitted.

The two terminal runtimes without that bridge use explicit launch contracts rather than a fake
tool registration. OpenCode receives the same snapshot through its documented `--file` option;
Grok Terminal receives a bounded inline `<conversation_history>` because its TUI has neither an
ephemeral MCP flag nor an opening-file flag. Capture itself is independent of delivery: Grok's
documented Markdown export and OpenCode's documented JSON export are converted once when they are
the source, after which no consumer depends on either provider's private storage format.

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
  session Threading launches — a far larger change than adding one. The settings-research
  one-shot is the deliberate exception (below): it is our process answering our question, and
  a helper that loaded the user's servers and built-in tools would spend the user's tokens
  reading capability the answer must not use.
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

## Scoped ad-hoc endpoints and the AI settings search

The settings search's Ask AI button runs a one-shot helper (`SettingsSearchResearch`) that must
see **one tool** — `list_settings`, the read-only catalogue of Settings pages — and nothing of
the session surface. Client-side flags alone cannot deliver that: `--allowedTools` is
pre-approval, not visibility, and a cheap model handed sixty schemas in `tools/list` spends its
run reading them. So the restriction is the server's:

- `MCPSessionRegistry.beginAdHoc(allowedTools:)` mints a **synthetic** session id, a token, and
  a scope. The id exists only in the registry; `endAdHoc` revokes it when the run finishes.
- The retain sweep (`retainOnly`) skips ad-hoc ids. They are not `ProjectStore`'s to revoke,
  and without the exemption a helper lost its endpoint mid-run whenever any unrelated session
  was deleted.
- `MCPServer` consults the scope in **all three** places the enabled catalogue is consulted
  globally — `tools/list` advertises `scopedDefinitions`, dispatch admits via `scopedAdmits`
  over the same list, and `initialize` carries `scopedInstructions` (only the groups owning a
  scoped tool, no panel addendum). The same-list invariant holds inside a scope or the scope
  is a lie.
- The scope deliberately ignores the user's group toggles: the run *is* the user's explicit
  click, naming exactly these tools. Toggles govern what full sessions may reach.

The launch line is built by `AgentLauncher.settingsResearchCommand` on whichever runtime claims
`.headlessResearch` (Claude first, then Codex — the first with an enabled login answers):
`codexResearchPlan`'s posture — default account through `env -u`, read-only sandbox, no session
of ours — plus the scoped MCP wiring. Claude runs `--print --output-format json --tools ''
--strict-mcp-config` with only `mcp__threading__list_settings` pre-approved; Codex takes the
per-run `mcp_servers` overrides plus `--skip-git-repo-check`, because the run works in a
scratch directory. The command lines are pinned word-for-word in `AgentLaunchQuotingTests`, and
the capability pairing (a plan exists exactly where `.headlessResearch` is claimed) is what
lets the Ask AI affordance hide by asking `SettingsSearchResearch.provider` instead of naming a
runtime.

`list_settings` itself answers with page ids, titles, groups and each page's search vocabulary
— `SettingsPages.all`, the same catalogue both search paths read. It holds no values: which
pages exist is not a secret, what is set on them stays behind the pages. The helper's reply is
JSON naming page ids; `SettingsSearchResearch.validated` lets through only pages the catalogue
vouches for (an unknown id gets one second chance as a title), so the UI never navigates on an
invented destination.

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

**A shown image is a row in the Attachments list, not a tab of its own.** Every `display_image`
used to open a tab that coexisted with the ones before it, so an afternoon of charts left a strip
of identical `photo` glyphs whose titles truncated to nothing in a 300pt pane — and the same call
had *already* recorded the file into `SessionAttachmentStore` before opening the tab. The panel was
stating one fact twice: once as a strip that could not be read, and once as a list that could. The
list is the chronology — newest first, dated, capped, persisted, pruned when a file goes; the
pane's preview and `MediaInspectorView` are the closeup. `display_html`, `display_scene` and
`display_compare_files` are unchanged, each being a document with nowhere else to live, and so is
a **browser capture** (`browser_screenshot`, an isolated run's final frame): those are evidence of
a page rather than a file this session exchanged, the store never recorded one, and their caption
is the page's own title — which a list identifying rows by file name would drop.

Three consequences worth keeping:

- **The tool points at the row it just made.** `record(declared:)` returns the `SessionAttachment`,
  and `SessionAttachmentsViewController.showAttachment(at:)` selects and scrolls to it — the
  identity comes from the store rather than from re-finding the file in the list, which matters
  because a declared file from outside the checkout is *copied* and so is listed under a path the
  caller never saw. Being asked to show a picture is an instruction, so it also resets the
  All/Agent/You filter when that filter would hide the row; the filter is a convenience.
- **A session with no project keeps the old tab.** `makeAttachments` needs a folder to belong to,
  so there is no list to route to. `DisplayContent.Body.image` and the image branch of
  `addContentTab` remain for exactly that fallback and for nothing else.
- **A persisted image tab converts on restore.** Its source is recorded through the declared door
  and the tab is dropped with its cached PNG; a source that has since been deleted drops the tab
  anyway, since the list prunes dead files regardless. The conversion is deferred until
  `tabsBySession` holds the session's tabs, and that ordering is load-bearing for the same reason
  it is in the store: recording announces synchronously, this controller answers by ensuring its
  Attachments tab, and that call re-enters `restoreIfNeeded` — which is a no-op only once the tabs
  are in place. Converting inside the restore loop re-restores the same layout per image until the
  stack is gone.

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
pans, and walks the source collection with arrows, swipes, or its thumbnail rail. Space, Escape, or
a click on the dimmed window around it closes and restores the source's focus — the surface opens
on a scrim over the whole content view, because the app's own header band is the one strip a
full-height inspector cannot cover and lit it read as the same chrome (see
[`window-chrome.md`](window-chrome.md)). The same route serves prompt thumbnails and the session
Attachments pane, so the interaction does not depend on first finding a row and invoking a
separate system panel.

**The hover a picture takes is the one fill in the app drawn over its content rather than under
it**, so it reads `Design.Surface.imageHoverWash` and not `controlHover`. That role is opaque
under System and under three stock themes — `unemphasizedSelectedContentBackgroundColor`,
Windows 98's `#D0D0D0`, Claymorphism's `#D8B4FE` — which is correct everywhere it is a control's
own ground and a lid here: pointing at an attachment replaced the whole image with a flat
rectangle. The wash keeps the theme's hue and states its own alpha (`Opacity.imageHoverWash`,
raised under Increase Contrast), leaving the accent outline and the pointer to say the picture is
a control. `DisplayPaneLayoutTests` asserts it off the drawn pixels across every stock theme,
because under a theme that happens to ship a translucent hover the wrong role looks right.

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

**The tab is not the only size the comparison has.** The surface's controls row carries a button
that opens the same pair in `CompareInspectorView` over the whole window (see
[`design-system.md`](design-system.md)), because a pane the divider decides is a poor place to
drag a seam across a screenshot. Nothing about the tab changes: the expanded view is handed the
mode and the scrub the tab is holding, and hands back whatever the user settled on, which arrives
at `CompareViewController` through the same `onModeChange` that persists the mode on
`PersistedTab`. The affordance belongs to `ImageCompareView` rather than to the tab, so a Git
Review image row got it in the same change without knowing it had.

**The comparison leaves the app as a comparison, not as a picture of one.** `CompareExport` is
the tab frozen into a `Sendable` value — the two sides' bytes, their pixel sizes, the mode, the
diff — and `CompareExportPage` writes it as one HTML document that reproduces
`ImageCompareLayout`'s rules in CSS: both sides fitted against the *union* of the two pixel
sizes so a resized asset stays visibly resized, captions in bands beside the pixels, the five
modes as buttons, the seam dragged or arrow-keyed. A screenshot of the tab would have lost
exactly the thing worth sending, which is that the recipient can ask difference the same
question the sender did. Nothing in the page loads from the network — a CDN in an exported file
is a page that stops working on a plane and reports every read to a third party — and the
document names the two files without their paths, because `git diff --no-index` reports absolute
ones and the sender's home directory is not part of the comparison.

Two formats, because they answer different questions: a single page inlines the images as
`data:` URIs and is one file to drag into a chat window, and a zip keeps them as files, which
avoids base64's third on every byte, hands the recipient the originals, and survives mail
clients that strip `.html` attachments. `ZipArchive` writes the archive itself — three records
that have not changed since 1993, against a package dependency for the same — deflating only
what actually shrinks, since a PNG passed through deflate reliably comes back larger. An image
a browser cannot draw (TIFF, HEIC) is re-encoded to PNG on the way out: the comparison would
otherwise arrive at half the recipients as two broken-image icons, which reads as *the files
were empty* rather than as *the format was wrong*.

Packaging runs off the main actor, which is what `CompareExport` being a value buys: base64 of
two 64 MB sides plus a deflate pass is not work to do between two frames, and by then the sheet
is gone and nothing on screen is waiting for it.

**The Compare tab's controls are in a header, and they are the surface's own.** `hostControls()`
hands `ImageCompareView`'s mode chip and expand button to the tab and stops the surface drawing
a row for them; the tab puts them in a row above its scroll view with the export button, Git
Review's shape without the band or the hairline — the pane's own header is the tab strip a few
points up, and a second banded header under it would read as chrome about chrome. Below the
canvas the controls were part of the scrolled content, so on a tall screenshot the modes left
the screen exactly when a reader had got far enough down it to want another one. Every other
host — the review row, the inspector — is unchanged, because the row is only detached where a
host has asked for it.

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

**It is also where the panel's per-image tabs went** — see the Display Panel section above for the
merge and its no-project fallback. The list had to become two things it was not to take them:

- **A row shows its own picture.** A column of file-type glyphs is precisely what the tab strip
  was, so a row that repeated it would have moved the problem one pane to the left.
  `SessionAttachmentThumbnails` decodes through `CGImageSourceCreateThumbnailAtIndex` at
  `thumbnailScale`× the row's well, which is bounded by the *row* rather than by the file — a list
  of full-screen screenshots is not 32 full decodes on the main thread — and caches by path **and
  modification date**, so a reload re-decodes nothing while a chart regenerated in place still
  refreshes. That date is read through `FileManager`, not `URL.resourceValues`: `NSURL` caches
  resource values, so the same `URL` value answers with the date it had the first time and the
  regenerated chart would keep its old thumbnail for the life of the process. A PDF and anything
  that will not decode keep the system's file icon rather than showing a blank well.
- **A row says when.** `referencedAt` in the caption voice beside the origin mark — the time of day
  for today, the day otherwise — and inside the row's single spoken sentence. A chronology whose
  rows carry no time is a list whose order has to be taken on trust, and the order is the whole
  reason the images stopped being tabs.

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

**The list is as tall as its rows, up to half the pane.** It used to be a constant 136pt —
three rows — whatever the session had exchanged, so eight attachments were read through a
letterbox while the pane's slack sat below the footer doing nothing; and this list is where the
panel's per-image tabs are going, which a fixed three rows cannot be. It now asks the table what
its rows measure (its row rects, so the padding the inset style puts above the first row and
below the last is not clipped off into a scroller a complete list has no reason to offer),
capped at `SessionAttachmentsDefaults.listShareOfPane` of the pane and scrolled past that. It is
re-asked from `refresh()` because the rows change and from `viewDidLayout` because the cap is a
fraction of the pane's *height* — the pair of reasons `updatePreviewHeight()` already had for
width. The cap is also what makes the height safe at `listHeightPriority`, *above* the preview's
`.defaultHigh`: a list that can never ask for more than half the pane cannot be what pushes the
buttons out of reach, so a pane too short for everything gives way in one order — the preview
first, the list after it, and the footer, whose floor is `required`, never.

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

**The scanned rule is a default, and the user may answer it — `includesAttachmentsOutsideProject`,
off.** It is the safety measure that has to survive being configurable, so widening it does not
relax what the endpoint stands on: an outside path admitted under the wide scope is *copied in*
like a declared file and marked `isOutsideProject`, so every listed file still sits somewhere the
app controls. Narrowing again is enforced at **read** — `attachments(for:)` is the one door the
pane, the MCP tools and the phone all pass through, so the gate closes for all three at once
whether or not anything was open to notice. The bytes stay in custody until the row leaves for an
ordinary reason, so the answer can be changed back without destroying what it already took.

Refused paths are remembered per session as `WithheldAttachmentReference` — a path and a kind, in
memory, never persisted and never served. That is what lets the pane's band say *how many* files
the rule is costing this session without the app taking custody of one byte, and what the widening
admits immediately: nothing re-reads a terminal's buffer on a settings change, so without it "show
me those" would be answered by an unchanged list until an agent happened to print the path again.

**The band appears only when the setting would change this pane.** A session whose files are all
inside its project is never asked about files outside it: a rule advertised where it costs nothing
teaches people to turn it off before they have ever needed it. It is a `PaneFooterView` at the
pane's floor — the actions row stops above it while it is there — with the count in the header's
own terse voice and a tertiary button saying what pressing it would do. `SessionAttachmentsLayoutTests`
pins the silence, the appearance and the effect.

**A listener may only ever see a finished store.** `admit` announces synchronously and the pane
answers by refreshing, which admits whatever is still withheld — so the withheld list is cleared
*before* the announcement, not after. The other order handed the listener the same work again and
the two recursed until the stack ran out: a segmentation fault, from turning a setting on.

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

**The opening prompt's images are a handoff too, and were the one that filed nothing.** The
session-start composer shows an attached picture, appends its path to the text it sends — a CLI
takes a path, never pixels — and used to stop there, so the only surface that can show a picture
before a session exists was also the only one whose pictures no session could show back. The
paths now travel beside the prompt (`SessionComposerViewControllerDelegate`) rather than being
parsed back out of the sentence, and `SessionCoordinator` files them through `PromptAttachment.record`
the moment the session id exists. A path recovered from prose would be a guess; this is a fact.

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

## Browser comparisons in the panel

`browser_visual_compare` opens its result in the panel as a `.browserComparison` tab —
`BrowserComparisonViewController` on `ImageCompareView`, with the computed diff map as a second view
and **Accept New Revision** as a user-only header action.

**That tab is deliberately not persisted, and the reason is a contract rather than an oversight.**
The panel's rolling browser-artifact ring (`cacheBrowserVisualArtifact`) evicts by count, so a
persisted tab pointing into it comes back after a relaunch naming files that have been swept — a
comparison showing two empty boxes, which is worse than no tab. The alternative was a comparison
bundle whose lifetime is tied to the tab; this codebase picked the other contract, because a
comparison is a moment rather than a document: the page has moved on by the next launch, and
re-running it is one tool call. The controller therefore holds its own bytes and
`persistedTab(_:)` has no branch for it.

The ring is still written, and the tool still reports `Actual PNG:` and `Diff PNG:` paths — a terminal
agent reads files, and an MCP image block is not one. The two uses are simply not the same use: the
ring is evidence with a lifetime, and the tab is a surface with bytes in hand.

The durable half lives elsewhere: baselines are project-scoped in `BrowserBaselineStore`, not in the
panel's per-session cache. See [`agent-browser.md`](agent-browser.md).
