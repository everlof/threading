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

The **Other sessions** group (`workspace-control`) is the first that sees past the calling
session — `list_sessions` and `send_to_session`, scoped to the calling session's own project.
The tools own wording only: scope, membership and every refusal live in
`WorkspaceControlPlane`, injected through `AgentToolDependencies`, so a future CLI or remote
binding cannot come away with looser answers than MCP gets. See
[`control-plane.md`](control-plane.md) for the contract, the per-surface delivery rules and
the provenance header every delivered message carries.

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

### Agent-facing discovery text

An MCP client may decide whether to load an individual tool schema from only the beginning of
the server's `initialize.instructions`. OpenAI's [MCP guidance](https://learn.chatgpt.com/docs/extend/mcp)
therefore requires the first 512 characters to be self-contained. `MCPToolCatalog.decisionPrefix`
owns that leading slice, and `MCPInstructionDefaults.decisionPrefixCharacterLimit` names the
budget. The all-groups regression test must fail if the prefix grows past it; do not truncate the
text at runtime, because a sentence cut in half is not guidance.

The prefix is a routing layer, not a miniature copy of the catalogue. It always tells an agent
that Threading tools may load lazily and that it must discover a matching tool before claiming an
in-app action is unavailable. It conditionally names only exceptional triggers whose miss is
costly or hard to recover from: cross-chat control (list, message, steer, wait, or inspect status),
Threading's own Browser, visual output, the user's explicit request to close this chat, and safe
disk-full recovery. The Browser route names `browser_navigate` and `browser_snapshot` because a
generic browser integration can also be installed in the agent host; the word "browser" alone is
not enough to select Threading's session-scoped surface. `browser_navigate` creates the session tab
when none exists, so an empty panel is not a failed capability probe. A disabled group contributes
no promise. Reordering whole groups to put one workflow first merely trades that miss for another
and is not a discovery fix.

The 512-character budget applies to the server instructions, not separately to every tool
description. Individual descriptions still begin with the action and the words a user is likely
to say, because those openings are what semantic or deferred tool discovery has to match. Put the
decisive trigger and outcome first ("close/archive this chat", "notify me", "No space left on
device"); put mechanics, examples, return shape, and edge cases afterward. Group instructions hold
cross-tool sequencing and constraints. State each rule once at the narrowest layer that can carry
it, and promote it into the decision prefix only when an agent must know the route before its
schema is loaded.

Tool results are **plain text, with one exception**. A display tool has already drawn its image,
so the result costs a sentence rather than an image's worth of tokens — and it sidesteps the
undocumented question of what Claude Code does with an image returned from a tool.
`browser_screenshot` is the exception, because visual inspection is the tool's whole purpose: it
returns a standard MCP image block as well as caching and optionally displaying the PNG. See
[`agent-browser.md`](agent-browser.md).

## Command contract

Built-in identity stays closed in `MCPBuiltInTool` so capability ownership is compile-time typed.
`MCPTools.authoredDeclarations` is the single per-tool authoring surface: each generic declaration
owns its identity and wire name, concrete argument decoder, schema, behavior annotations, family,
group, Settings presentation, trace and workspace policy, panel-observation policy, and typed
application implementation binding. `MCPBuiltInToolRegistry` admits exactly one complete
descriptor per identity. A missing or duplicate declaration is omitted instead of being decoded,
advertised, enabled, or dispatched ambiguously.

`MCPToolCatalog.swift` now owns only group-level instructions and ordering; its tool rows are
projected from admitted declarations. Decoding, advertised definitions, enabled names, catalogue
rows, scoped definitions, Settings presentation, completeness checks, and execution all consume
the same descriptors. `AgentCommand` is a typed closure-backed value, not a payload enum: the
concrete `Sendable` argument value captured by the generic declaration reaches the matching
`MCPBuiltInToolExecuting` implementation without `Any`, string routing, or a command switch. Do
not bypass that registry with another name list or a direct built-in dispatch switch.

The catalog is also the runtime admission policy. `tools/list`, launch preapproval and
`MCPServer` dispatch consume the same enabled definitions. A valid built-in command whose group
is disabled still decodes for diagnostics, but `MCPToolCatalog.admits` refuses it before the
application handler runs. External extension tools use a separate open-world path and are
omitted when their names are blank, duplicate another enabled external tool, or collide with a
built-in.

`MCPToolCall` remains only as a compatibility alias at the transport boundary.
`AgentToolCoordinator` implements the narrow typed execution protocol and common observation
policy, while capability extensions own project, display, panel, extension-authoring,
browser-interaction and browser-inspection behavior. Adding a built-in requires its closed typed
identity, one complete declaration, and the typed implementation—there are no decoding,
catalogue, annotation, or UI-routing inventories to edit in parallel.

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

`list_settings` itself answers with page ids, titles, groups, each page's search vocabulary,
and the individual settings a page holds (title plus section). Built-in rows are projected from
`AppSettingDefinitions.all` through `SettingsPages.all`, the same catalogue both search paths
read; extension pages join at that projection. It holds no values: which
pages exist is not a secret, what is set on them stays behind the pages. The helper's reply is
JSON naming page ids and optionally a setting's title; `SettingsSearchResearch.validated` lets
through only destinations the catalogue vouches for (an unknown page id gets one second chance
as a title; an unknown setting title quietly degrades to the page), so the UI never navigates
on an invented destination. A vouched-for setting travels to the suggestion row as its anchor:
the row shows the full path ("General › Notifications › Alert sound") and opening it scrolls
to and marks the row through `SettingsRowReveal`, the same jump the sidebar's keyword results
make.

The answer is deliberately hard to lose once bought. The suggestions surface is a
`NavigationHistory.Page` (`.settingsAISearch`), so opening a suggestion leaves it one Back
step away; and `SettingsAISearchViewController.begin` re-shows a held answer for an unchanged
query instead of re-running, which makes the Ask AI button itself the other way back. Only a
changed query spends a new run.

## Display Panel

The panel normally belongs to the selected session and presents that session's persisted tabs.
**Current Theme is the deliberate app-wide exception.** It temporarily replaces the visible tab
strip with one non-persisted inspector while leaving both per-session tab lists untouched. It is
not offered by the tab `+`, cannot be reordered or transferred, and stays visible when the user
selects another conversation. An explicit request for a session surface — Browser, Review,
Terminal, Activity, Info, Attachments, Subagents, or a transferred tab — exits the inspector and
returns to the selected session's tabs. This lets a conversation remain alongside the theme being
discussed without pretending an app-wide document belongs to that conversation.

`DisplayContent.Body` is an enum, so the panel shows a `ThemedImagePreview`, a `WKWebView`, or a
native semantic scene and the `⋯` menu offers only the actions that fit — an image and a document
share almost nothing worth acting on.

**Activity is the filesystem-shaped account of agent work.** The former Files tab keeps its
persisted `.files` body and `view.files` command identity for layout and shortcut compatibility,
but presents as Activity. `AgentWorkSummaryView` supplies the bounded repository atlas and recent
action overview above `FileTreeViewController`; the outline below remains the ordinary lazy file
browser and annotates its visible rows with exact read/edit totals. A directory total is maintained
incrementally from file events, not computed by walking its subtree. Row queries contain only the
current viewport, cache at most 256 paths, and run through `AgentWorkTraceStore`'s utility worker.
Closed directories are neither enumerated nor represented by views merely because the pane opened.

**Observed work has two feeds, and the second one is why the panel is not empty for most chats.**
A rendered conversation records each tool call as it streams, from `ConversationViewController`.
A session Threading does not render has no such stream — its calls reach us as PTY bytes — so for
a long time Activity drew the whole repository and reported zeros beside it: measured on this
machine, 179 of one project's 183 sessions. `AgentWorkHydration` closes that by folding the
session's *own transcript* in, through `TranscriptReplay.toolCalls`, which is `read`'s sibling:
same closed `TranscriptReplayFormat` set, same record-to-event mapping, two deliberate
differences.

- **It resumes.** `JSONLReader.forEachRecord(at:from:limit:)` returns the position just past the
  last record delivered, and `AgentSessionWorkTrace.transcriptOffset` persists it beside the work
  it counted. The in-memory call-id dedupe cannot survive a relaunch; this can, which is the
  difference between re-reading a transcript and re-*counting* it.
- **It keeps each record's own timestamp.** `[StreamEvent]` carries none, which is why the replay
  seed stamps its whole reduction `distantPast` — honest for a footprint, useless for recency, and
  actively wrong here in a second way: stamping folded-in work `Date()` would light the map's glow,
  and start its refresh timer, for every old session whose tab was opened.

Three rules keep repeated passes honest, and they live in the worker beside the trace:
a trace holding work but no offset is a conversation that **changed surface**, so the transcript is
adopted at its current end rather than counted from the top; a file **shorter** than the position
already consumed is a different conversation (a fork's copy, a rewritten rollout), so that session
starts over; and everything else is `size > offset`, which is the entire cost of a pass with
nothing to do.

That cheapness is what lets the trigger sites be blunt: the `turnFinished` lifecycle hook a
terminal session already carries, the inferred activity edge for a session whose runtime or user
has no hooks, and the Activity tab opening. **No hook is registered per tool call** — every hook
is a process spawned on the agent's own turn boundary, so that would buy this panel with the
user's latency on every `Read`, and the transcript already holds every call by the time the turn
ends. Measured, Debug: 2,000 calls fold in in 184 ms on the worker queue, a resumed pass over the
same file costs 0.07 ms, and twenty triggers cost 0.3 ms *on the main actor* between them. Calls
are applied one at a time through the same incremental path live events take — the first shape
merged a delta trace and called `rebuildDirectories`, which is O(every file every session in the
project has touched), per turn, for a reading that changed one directory.

This is capability-shaped, not runtime-shaped: `.transcriptReplay` is the fact that a normalizable
local conversation exists, so Claude and Codex are covered today and a sixth runtime is covered the
day it earns the capability. What a transcript cannot say stays unsaid — a shell edit no tool
named lights no file, exactly as for a rendered conversation. The remaining runtimes, the git-
observed floor for them, and the empty state that should replace "0 of N files" for a session with
no source are in
[`observed-work-for-terminal-sessions.md`](../feature-drafts/observed-work-for-terminal-sessions.md).

**The panel's one header row ends in two controls: `+`, and the panel's own toggle.** The toggle
sits outermost with `+` beside it, and it runs through the same `onClose` the last tab closing
already used, so the window collapses the split item one way rather than two. It hides nothing
but the pane: the tabs are waiting when the panel is next opened, as a dormant session's
scrollback is. It is the *pane's* control, not a tab's — a tab chip carries its own ✕, drawn on
the chip. Current Theme hides `+` and the session-only decoration beside it, because those act on
a chat's tabs and the global document is not one; the toggle stays, because the pane is on screen
either way. The sidebar at the other edge of the window has no equivalent — it is one column with
one toggle, and the trailing panel is the pane that arrives unasked when an agent displays
something, which is what earns it a way out where the eye already is.

**That corner control is the *same* toggle the session header holds, not a second one.**
`DisplayPanelToggle` states the symbol (`sidebar.trailing`) and the copy once; the session
header's actions group draws it while the panel is shut, and `updatePaneToggleSelection` hides
that copy for exactly as long as the panel draws its own — so the switch is never offered twice,
a pane's width apart. Both are `.toolbar` icon buttons at `PaneHeaderDefaults.inset` from their
pane's trailing edge, and the two headers are one band, so the button is at the same point of the
window in both states: pressing it opens the pane **underneath a control that never moved**.
`DisplayPaneLayoutTests.testThePanelsToggleKeepsItsPlaceWhenThePanelOpensUnderIt` asserts the two
frames match in the window's coordinates, which is the whole claim.

The corner held an `xmark` first (2026-08). It read as "close" where the toolbar read as
"toggle", and — worse — the act of opening the panel pushed the real toggle a pane's width to the
left of where the eye had just been, so the way back was neither where it was pressed nor what it
looked like. The ink still differs by ground and should: the panel paints itself in the app
theme's surface (`inkSource: .chrome`) while the toolbar's copy floats over the terminal's
palette (`.backdrop`). Same control, same place, each inked for what is behind it.

The floor moves with that row. `DisplayPaneDefaults.slimmestWidth` is stated as its parts —
`PaneHeaderDefaults.inset + toolbarButtonWidth + controlGap + toolbarButtonWidth` — so adding a
control moves the number rather than leaving it a literal that quietly stops meaning "the pane's
own chrome". Matching the session header's button size raised it from 60 to 82, and a pane
minimum is also a window minimum: 22pt of window width is what the corner control being the
*same button* costs. What the floor does *not* include is the tab strip: both of the strip's
trailing constraints sit at 999, so at the floor the strip closes to nothing instead of being
asked for a negative width and having AppKit break a required constraint to grant it. That is the
same rule the strip already follows for `fittingSize` (below), stated in the one other place the
pane could still charge for it.

**Shown image and HTML output are attachments, not a second presentation model.** Every `display_image`
used to open a tab that coexisted with the ones before it, so an afternoon of charts left a strip
of identical `photo` glyphs whose titles truncated to nothing in a 300pt pane — and the same call
had *already* recorded the file into `SessionAttachmentStore` before opening the tab. The panel was
stating one fact twice: once as a strip that could not be read, and once as a list that could. The
list is the chronology — newest first, dated, capped, persisted, pruned when a file goes; the
pane's preview and `MediaInspectorView` are the closeup. HTML is the same kind of durable evidence:
`display_html` writes the supplied bytes into the session attachment store and the Attachments pane
previews them in a non-persistent `WKWebView`. `display_scene` and `display_compare_files` remain
live panel documents, and so does a **browser capture** (`browser_screenshot`, an isolated run's
final frame): those are panel state rather than a file this session exchanged.

This distinction is the notification boundary too. A generated image or HTML document is copied
as an **immutable capture**, even when its source is already in the checkout. Reusing
`progress.png` for ten steps produces ten attachment identities and ten preserved byte sequences;
a notification for step three must never reopen step ten's overwritten chart. Hosted work is not
turned into synthetic HTML: `browser_navigate` points at the live browser tab that loaded its URL.
Extension panels remain semantic live panels. On iPhone, the process continues to run on the Mac
while the existing `ExtensionPanel` tree is rendered with native SwiftUI controls and actions are
relayed against the generation that produced it. A companion `remoteSurface` is deliberately not
mirrored as pixels; its required semantic root is the portable fallback. There is no
`Presentation`, `Inspection`, or generic web-payload object beside Attachments just to make these
things addressable.

Three consequences worth keeping:

- **The tool points at the row it just made.** `record(declared:)` returns the `SessionAttachment`,
  and `SessionAttachmentsViewController.showAttachment(at:)` selects and scrolls to it — the
  identity comes from the store rather than from re-finding the file in the list, which matters
  because a declared file from outside the checkout is *copied* and so is listed under a path the
  caller never saw. Being asked to show a picture is an instruction, so it also resets the
  All/Agent/You filter when that filter would hide the row; the filter is a convenience.
- **A session with no project keeps the old tab.** `makeAttachments` needs a folder to belong to,
  so there is no list to route to. `DisplayContent.Body.image` / `.html` and their branches of
  `addContentTab` remain for exactly that fallback and for nothing else.
- **A persisted image tab converts on restore.** Its source is recorded through the declared door
  and the tab is dropped with its cached PNG; a source that has since been deleted drops the tab
  anyway, since the list prunes dead files regardless. The conversion is deferred until
  `tabsBySession` holds the session's tabs, and that ordering is load-bearing for the same reason
  it is in the store: recording announces synchronously, this controller answers by ensuring its
  Attachments tab, and that call re-enters `restoreIfNeeded` — which is a no-op only once the tabs
  are in place. Converting inside the restore loop re-restores the same layout per image until the
  stack is gone.

`display_chart` is how an agent reports numbers. It takes **data, not geometry** — `categories`,
one `series` of values each, a unit, a format — and Threading owns the scale, the axes, the ticks,
the legend, the categorical palette, hover, focus and the VoiceOver summary. That altitude is the
whole point of a separate tool: `display_scene` below asks the caller for normalized rectangles,
and a model asked for rectangles will confidently draw a 42 shorter than the 18 beside it. Nothing
about the appearance crosses the wire, so a chart drawn in one theme and reopened in another is
right both times.

It renders on the chart stack the Usage dashboard already uses. `ThemedChartModel` gained a mark
(line or bar), an x-axis mode (time or categories) and an orientation; `ThemedChartGeometry` was
not touched. Two consequences worth knowing before changing either:

- **A categorical axis is an ordinal domain carried in the time slot** — category *i* is second
  *i* — so one downsampler, one stacking rule and one interpolator serve both domains. A parallel
  scale type would have duplicated all three and let them drift.
- **A band scale falls out of the range, not out of new code.** `ThemedChartModel.categorical`
  widens the domain to `-0.5 ... n-0.5`, which centres each bar in a band of equal width; without
  the half-step the first and last bar are cut in half by the plot edges. A bar is then just
  `baselineY → y` in the space a line already uses, so **grouped and stacked bars need no geometry
  of their own**: `.independent` puts every foot on zero and `.stackedBands` puts it on the running
  total, both already computed for the curve grammar.

**A chart's words are text, and were measured as such.** Drawn in `Design.Text.tertiary` — the
right role for chrome — the axis ticks and category names came out at **3.03:1** against a light
ground, and the grid rules at 1.88:1: correct by the design system's vocabulary and too faint to
read. Axis text is now `secondary` (7.8:1), a bar's own number is full `label` strength (14.9:1)
because it is the content rather than the chrome, and the system grid alpha went 0.42 → 0.68
(3.95:1). `ChartTests` renders the card in both appearances and measures the dominant text colour
against its own background, so a role change that dims the axis again fails rather than merely
looking wrong. This is shared with the Usage dashboard, deliberately: its axis had the same
problem.

Three more rules here were arrived at by rendering the fixtures and looking at them, and every
assertion passed while each was wrong. A chart whose view is left on its autoresizing mask keeps
the zero frame it was built with and draws a perfect title over an empty rectangle. A bar's own
number lands next to a grid rule by construction — the top of a tall bar is near a gridline — so
it is drawn on a plate of the chart's own background, and **a stacked bar prints no per-segment
number at all**: the figure reads as a running total, and its plate punches a hole in the rule
behind it. Finally the value axis is rounded up to a *nice* ceiling (`ChartCardView.axisCeiling`)
rather than fitted to the data, because a true axis labelled 73.4 ms and 55.1 ms tells nobody
anything; the step ladder is fine-grained because a coarse one leaves a third of the plot empty.

**A tab that holds a value builds its own controller, and the pane has to own it.**
`installedController` is weak on purpose — it points at controllers the *tab* keeps alive, like a
browser or a review — so a controller the pane constructs from data (a chart, a semantic scene)
has no other owner: it deallocates the instant it is installed, the weak reference empties, and
the next `installHosted` finds nothing to unparent. The orphaned view then stays in the panel for
the life of the session with every later tab drawing on top of it. `ownedController` holds those,
and the assignment happens *after* the outgoing view is unparented — releasing first reproduces
the original bug exactly. Reported from the running app as "the tabs overlap", and the scene path
had been doing it since it shipped.

**Pane content states height as a preference.** A required height constraint inside the panel
becomes the window's own minimum size, so a chart in the side pane stopped the window being made
shorter until its tab was closed. The card's minimum is `.defaultHigh` and the chart's vertical
compression resistance is low, so a short pane compresses the plot instead of pinning the window
open. `ChartTests` asserts there is no required height constraint anywhere in the card.

The same `ChartCardView` serves both surfaces, so the panel and the transcript cannot disagree
about what a chart looks like. In a natively rendered conversation the chart is drawn **inline, on
the tool call that produced it** — `ConversationTimeline.ToolCall.chart`, decoded from the call's
own arguments exactly as its diff is, so the row is the record of what was done *and* the picture
it produced rather than a line saying a chart was drawn somewhere else. A chart row survives the
turn fold for the same reason a decided permission card does: it is part of the answer, not work
done on the way to it. A refused call falls back to the ordinary tool row and shows what the panel
said about it. Terminal sessions get the pane tab only, which is also the only surface that
persists.

`ChartSpec` validates at the boundary and **fails loudly with a sentence the caller can act on** —
which series, how many values, how many categories — because the caller is a model holding the
data and can fix its own call; a silently truncated chart is a wrong picture with no warning. The
mark cap is on the *product* of series and categories and sits well below the two per-axis caps
multiplied together, or it would never refuse anything. The tab keeps the values, so `Copy Chart
Data` hands back a TSV: a picture of numbers you cannot get the numbers out of is a dead end.

`display_scene` is the generic non-HTML visualization bridge, and after `display_chart` it is for
geometry the caller *already has* rather than for measured values. Its value is the same bounded
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
- **`NSSplitView.setPosition` does work under `NSSplitViewController`, but divider indices are
  indices among items, not among the split view's private divider subviews.** The earlier
  `subviews.count`-derived index addressed the wrong divider and looked like a rejected move.
  `applyDisplayPaneWidth` derives the trailing divider from `splitViewItems` and moves it inside
  the uncollapse geometry group, so the restored width becomes the split view's own held answer
  without a second animation.
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
sizes so a resized asset stays visibly resized, captions in bands beside the pixels — inked by
the same ramp the app's are, so a title in the exported page also grows into view with its
picture and the horizontal wipe's band divides where its seam does — the five
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

Activation returns a notification `target_ref` only where the tab has a real identity beyond
its current presentation: a Browser tab has its host-owned UUID, and an extension panel has its
registered extension and panel ids. There is intentionally no generic "whatever is painted in
this tab" route. If a transient scene or comparison is evidence that must survive until a later
notification tap, the agent captures it as an image or HTML Attachment; if it is an ongoing tool,
it belongs in a Browser or extension panel. That keeps notification routing from quietly turning
the tab implementation into a second attachment system.

**Tabs move between hosts, and the agent contract holds still.** `TabTransferCoordinator`
(window-owned — only the window sees both hosts) reparents the same `PaneTab` between the
panel and the drawer: detach without teardown, adopt, both sides persist their own slice.
Movement is bounded by what the destination could *restore* after a relaunch (`canAdopt`), so
a moved tab is never one the layout later forgets — which is why shells and browsers travel
and the singleton surfaces stay panel-side. `panel_list_tabs` / `panel_activate_tab` remain
display-panel-scoped: a tab moved out disappears from them exactly as a user-closed one does,
and the existing "the user changed it while you were away" prose covers it.

**`browser_*` follows the browser, and one type says where it went.** `SessionBrowserResolver`
(window-owned, for `TabTransferCoordinator`'s reason — only the window sees every host) asks
each host in preference order and hands back the browser, its tab id, and its `TabHostID`. The
panel answers first: it is where a browser is built and where a session with none gets one.
Hosts answer through `SessionBrowserHosting`, deliberately **not** folded into `TabHosting` —
that protocol reports what a strip *draws now*, and the panel showing the app-theme document
draws no session tabs while still holding the browser the agent is driving.

This replaced a fallback closure hanging off the panel, which leaked in both directions the
moment a browser could live elsewhere. `browser(for:)` consulted it and `activateBrowser` did
not, so `browser_navigate` built a *second* browser in the panel beside the one the user had
moved and then drove the invisible one. And the page lease resolved its browser across hosts
while confirming its *tab* in the panel alone, so `currentBrowserPageLease` returned nil for
every moved browser and each gated tool — snapshot, click, type, screenshot, console, network
— answered "No authorized page is loaded. Use browser_navigate first." about a page plainly on
screen. One resolver consulted by resolution, activation and the lease alike is what stops the
three from disagreeing again.

**Preference is narrower than possession**, and the gap between the two was a bug. The Execution
audit owns a live browser so its split mode can put tool calls beside the page they affected —
but in plain audit mode that browser is hidden and has never loaded anything, and opening the
audit makes it the panel's *active* tab. It therefore became the session's browser outright, and
every lease-gated tool answered "No authorized page is loaded" about a page still sitting in the
browser tab beside it. `PaneTab.holdsAgentDrivableBrowser` is what a host offers as *preferred*
— an audit qualifies only while it is actually showing its browser — while `PaneTab.browser`
still reports what a tab *holds*, because a lease re-checking where its browser lives must find
it whatever kind of tab it is in, and the remote mirror lists what exists. A session whose only
browser is a hidden audit's has, for the agent, none: navigation builds a real one rather than
driving the blank.

That distinction is the standing answer to a wider question. Fixed host order is preference *by
geography*; it is right for panel-before-drawer, and it stops being right the moment a tab holds
a browser for some other purpose. A new host inherits the rule, so `holdsAgentDrivableBrowser`
is where a future surface that happens to embed a browser states that it is not the session's.

A tool that *drove* a browser reveals the pane that holds it (`revealBrowserPane`), not the
panel by reflex; `revealDisplayPane` stays what panel content uses. `browser_tabs`
list/activate/close is still panel-scoped, so a browser resolved in the drawer is not in the
list the agent can act on — pre-existing, and the decision it waits on is whether an agent may
close a tab in the user's own drawer.

## The detached browser window

A browser tab moves into a window of its own, and back. The point is a developer's app on a
second display at real size — fullscreen if they want — with an agent still driving it and the
main window still holding the conversation.

It is a **third tab host** (`TabHostID.detachedWindow(UUID)`), not a new mechanism: the move
goes through `TabTransferCoordinator` exactly as a pane-to-pane move does, so the browser keeps
its page, history and signed-in state. One difference matters and everything else follows from
it — **the window is pinned to one session** where both panes follow the selection. So
`DetachedBrowserHostViewController` stores its session and *checks* the `sessionID` arguments
the host contract carries rather than resolving them; a host that answered for whatever session
it was asked about would hand another session's agent the wrong page.

**Browsers only, shared only.** `canAdopt` is bounded by what a host could restore, and a
private context is ephemeral by definition. Shells are refused for a second reason:
`WindowBackdrop` is one app-wide value describing the *main* window's terminal palette, and a
shell dragged into another window would ink itself for the window it just left. `canHold` is a
static so the menu offering the move and the move itself cannot disagree.

**Native chrome**, following `window-chrome.md`'s scope decision and the Component Gallery's
precedent. A takeover here would need a `TitlebarActionWindow` and a whole app-drawn content
root, which is its own piece of work.

**Detached windows answer `SessionBrowserResolver` last**, after both panes: a browser the user
is looking at in a pane is still the session's, and a window parked on another display answers
only when no pane holds one. An agent's reveal **orders that window front but never makes it
key** — a tool acting on a page must not take the keyboard from under what the user is typing;
`showWindow` is what the user's own move does.

**Restore is eager at launch, and the window is ordered on screen.** Every pane restores on its
first *ask*, which is invisible because a pane is not on screen until its session is either —
but nothing ever asks a window into existence. Hanging restore on session *selection* is
therefore not "eager" in any useful sense: `relaunchSessionsFromLastQuit` relaunches sessions
without selecting them, so the headline case — a fullscreen browser on a second display —
would wait until the user happened to click that session.
`restoreDetachedBrowserWindowsAtLaunch` scans the sessions' `panel_layout` rows instead, gated
on the same two switches that decide how much of the workspace returns at all. That scan is
cheap and reads no conversation: a layout is a small JSON document in its own table,
deliberately not foreign-keyed to `session`, and building a browser needs a session id and
nothing else. Ordering the window in is not cosmetic either — WebKit renders nothing for a view
in a window that was never shown, so a restored-but-unshown window would hand an agent blank
captures forever (`BrowserOffScreenCaptureTests`). It is ordered *front*, never made key:
restoring a workspace is not a request to type into a browser.

**A move keys off the tab's session, not the selection.** Both panes follow what is on screen,
so the two agreed until a host could be pinned: dragging a tab back from a window bound to
session A while the main window showed B put it in B's panel and took the page with it. The
move now reads `PaneTab.owningSessionID` and brings that session forward when it differs — a
move that lands where the user is not looking is the same as losing it.

**The window answers the tab commands itself, and that is why the menu items are nil-target.**
`AppDelegate` routes every command through the main window controller deliberately, which was
right while there was one window. An untargeted item walks the *key* window's responder chain
first, so a detached window intercepts ⌘W, ⇧⌘[ / ⇧⌘] and ⌘1–9 simply by implementing the same
selectors, and everything it does not implement still reaches the application delegate
unchanged. Without that, the commands did not fail — `MainWindowController.closeActiveTab`
resolves its target from the main window's `firstResponder`, which a window keeps while it is
*not* key, so ⌘W closed a tab in the window behind. Nothing about that is a type error, which
is why the coupling between the two selector sets is asserted in a test.

**The drag is asked in screen coordinates, and every host is a candidate.** Both were pairwise
while there were two panes: each source mapped to *the* other one, and window points were
unambiguous because both ends shared a window. A detached window breaks both assumptions at
once — there is no window whose coordinates the panel and a separate window share, and "the
other host" stops being a thing. So the strip still reports its own window's point, the window
controller converts it to screen space at the source, and `dropBandHosts` enumerates every host
that can take a drop; each converts back into its own window to answer.

**The panel keeps a chip saying where a page went** — the panel specifically, wherever the page
was detached from, because it is the pane that is always there to carry one. Without one the tab simply vanishes
and the only way back is a menu on a strip that no longer shows it. The proxy carries the
window's own title, draws the window glyph rather than a second globe, and offers **Focus
Window** and **Bring Back to Panel**.

It is deliberately **not** a `PaneTab`. The panel does not hold that page, and `panel_list_tabs`
must keep saying so — a tab moved out disappears from the agent's list exactly as a closed one
does. The proxy is synthesized in `renderTabBar` alone, so `tabs(for:)`, the resolver and the
lease never see it. It is the answer to "where did it go", which is a question the *user* asks.

It also draws **no ✕**, which is why `TabStripItem.showsClose` became a per-item override
instead of the strip-wide setting it was. Every honest meaning for that ✕ is wrong: closing the
window from one misclick ends pages this chip only points at, and a ✕ that instead brings the
page home is the one chip in the app whose ✕ does not end what it names. A chip that stands for
something rather than holding it should not offer to destroy it.

**A chip carried out of its window makes a new one** (`DragLanding.newWindow` — a tear-off is not
a host, which is why the landing is not simply a `TabHostID?`). The rule is *outside the source
window's own frame*, not merely outside a band: the looser test would make a window out of every
drag that overshot the strip by a few points, and an unwanted window costs far more to undo than
a chip that springs back. Leaving the window a tab lives in is something a hand does on purpose.
A detached window's **last** tab does not tear off either — the source would close as the
destination opened, which is an expensive way to move a window.

The new window lands **under the pointer that dropped it**, clamped to that screen's visible
frame, where the menu's "Open in New Window" cascades off the main window instead: the two
entrances place it differently because only one of them was told where. The affordance while
travelling is the existing one — the chip dims (`Design.Opacity.dragAway`) as soon as a drop
would land, which now includes "outside, into a window of its own". A ghost the user can watch
cross the gap is not built; the dim plus the window arriving under the hand is what says it
worked.

Only the two **panes** spring open for a travelling chip. A detached window is not a pane the
app can open on the user's behalf — it is on screen or it is not, and one summoned by a drag
passing over where it used to be would be a window appearing from nowhere.

**A host answers a geometry question; the window answers whether that host can be dropped on
at all.** An earlier pass reasoned that screen coordinates made a visibility check redundant —
that a hidden window's band could not contain the pointer's screen point. That is false for
exactly the windows this feature adds: miniaturized, occluded and other-Space windows all keep
their frame, so their bands *do* contain live screen points. A fullscreen browser on the second
Space owns the top strip of the whole screen, and a drag near the top of the first would have
posted the tab into a window nobody can see. `isWindowUsableForDrop` now asks the real question
— visible, not miniaturized, not occluded — in the controller, leaving the hosts' band geometry
answerable by a built-but-never-shown fixture window, which is how every test here builds one.

Two entrances, one move: the chip's **"Move to …"** menu items, and **dragging the chip onto
the other strip's band**. The strip asks the window on every pointer sample
(`externalDropTarget`), dims the traveller while a drop would land
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

**Six kinds, one explicit map.** Images, PDFs, HTML, archives (`zip`/`tar`/`gz`/`7z`/…), open
document formats (ODF, OOXML, `rtf`) and diagram source (`dot`/`gv`/`mmd`/`mermaid`) —
`AttachmentReferenceDetector.kind(for:)` names each family explicitly. It used to answer `.image` for anything on the extension list that was not a
PDF or HTML, which was correct only while images were the remainder, and one added extension
away from the pane decoding a zip as a picture. The alternation the scanner builds from the
list is sorted longest-first, because nothing after the group requires a word boundary: with
`tif` offered before `tiff`, `shot.tiff` matched as `shot.tif` — a file that does not exist —
and the real one was never recorded. Previews route by kind: images through
`ThemedImagePreview`, PDFs through PDFKit, archives and documents through Quick Look — the
latter two inside `MediaInspectorDocumentView`, the one named system-chrome boundary, so an
archive previews as the same icon-and-metadata card the space bar shows in Finder. Diagram
source previews as *itself*, in a read-only `ThemedTextView` capped at
`maximumSourcePreviewBytes`: the app carries no Graphviz or Mermaid engine, and rendering one
would mean either the pane fetching a CDN library on row-selection or vendoring the renderer —
both deliberate decisions, neither taken here; the display panel already renders a diagram when
an agent writes `display_html` that pulls the library in. Only images and PDFs join the media
inspector's rail; only images can be a side of a comparison. A
persisted row whose `kind` this build does not know re-derives it from the file's own
extension, and drops alone when both are unknown — decoding used to be all-or-nothing per
session, and the next admission then persisted the fresh rows over a payload that still held
every older one.

**Space on a row is Finder's preview key, answered by the app's own inspector.** The list itself
carries no policy: `ThemedTableView.onQuickLook` reports the bare key and the trackpad's preview
gesture the way `onContextMenu` reports a right-click, and a `false` answer leaves the event with
AppKit — a list with nothing to preview keeps type-select, and Command-Space is never claimed.
The pane answers in three ways, one per what the inspector can actually hold: an image or a PDF
opens *on the rail* (`mediaInspectorSelection(forRow:)` — the same collection the picture below
the fold hands the inspector, so the two routes cannot drift); an archive or an office document
opens as a single `.document` item through `MediaInspectorDocumentView`, the boundary already
rendering it below the fold; HTML and diagram source decline, because the pane renders those
itself — a non-persistent `WKWebView` and a `ThemedTextView` — and routing them through the
inspector would hand both to a system previewer instead, which is the decision the non-persistent
data store was made to avoid. Declining costs nothing: that row's preview is already on screen.
Opening is not `perform`, so the footer's remembered action does not move — looking at a file is
not a choice about what to do with it, exactly as double-click's comment says from the other end.

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

**The pane is two panes, and the footer is a band.** The list is one half, its preview the
other — a full-bleed `SeparatorView` folds them apart, and the preview is the layout's one
flexible element, filling whatever stands between the fold and the footer. The footer is a
`PaneFooterView` at the pane's floor: the selected file's name over its path on the leading
side, the action control on the trailing side, one centreline between them. An earlier design
computed the preview's height from its content so the footer could hug the picture; the strict
split replaces all of that — nothing in the pane states a content-derived height any more
except the list's own (see below), which is also what keeps every constraint here under
`windowSizeStayPut` (a content height at 500+ is the pane resizing the *window*; a full-page
screenshot once grew the main window to 3386 points). A pane too short for everything gives
way in one order: the preview first, the list after it, the footer never.
`SessionAttachmentsLayoutTests` pins the floor, the band and the order.

**The footer's action is the one the user last took — Finder's pattern, the header control's
rule.** Four buttons (Open / Finder / Copy Path / Chat…) became one `ThemedButton` whose press
performs the remembered action, with a chevron (`ThemedIconButton`, `.besidePrimary`,
`presentsMenu`) beside it presenting the same entries as the row's own context menu — one
builder, `contextMenuEntries(for:)`, so the two surfaces cannot drift. Choosing a rememberable
action (`AttachmentAction`: open, reveal, copy path, copy file, add to chat) from *either* menu
records it through `PreferenceStore` (`SessionAttachmentsDefaults.lastActionKey`) and retitles
the button; the extras — Open in, Compare with, Comment — stay direct, because none of them is
a single press's worth of decision. `AttachmentAction.resolvePreferred` is pure for
`ExternalApps.resolvePreferred`'s reason: a remembered Chat falls back to Open while nothing is
listening, without the memory being overwritten, so the door reopening restores the remembered
answer. A double-click on a row opens without touching the memory, exactly as Finder's does.

**Several rows are a batch.** The list allows multiple selection, and a drag from a selected
row carries every selected row's file — AppKit asks `pasteboardWriterForRow` per row, and the
places a batch lands (a composer, a terminal, Finder) already take several files in one drop.
The preview cannot show three pictures, so it and the footer say the count instead, and the
footer's action applies to all: reveal selects them together, Copy Path joins one path per
line, chat stages one receipt per file. The chevron's batch menu (`actionMenuEntries`) keeps
only the actions that mean something said of several files — no Open in, no comparison, no
comment, each a decision about one thing. A secondary click inside the selection does not
collapse it (Finder's rule); the row menu still speaks for the row under the pointer.

**The list is as tall as its rows, up to half the pane.** It used to be a constant 136pt —
three rows — whatever the session had exchanged, so eight attachments were read through a
letterbox while the pane's slack sat below the footer doing nothing; and this list is where the
panel's per-image tabs are going, which a fixed three rows cannot be. It now asks the table what
its rows measure (its row rects, so the padding the inset style puts above the first row and
below the last is not clipped off into a scroller a complete list has no reason to offer),
capped at `SessionAttachmentsDefaults.listShareOfPane` of the pane and scrolled past that. It is
re-asked from `refresh()` because the rows change and from `viewDidLayout` because the cap is a
fraction of the pane's *height*. The cap is also what makes the height safe at
`listHeightPriority`: a list that can never ask for more than half the pane cannot be what
pushes the footer's action out of reach, so a pane too short for everything gives way in one
order — the preview first, the list after it, and the footer, whose band is `required`, never.

**There are two doors into the list, and conflating them was the bug.**

| | admitted | served to a paired phone |
|---|---|---|
| **scanned** — terminal output plus intact terminal-turn transcript prose, a native conversation's finished assistant prose | inside the checkout only | yes |
| **declared** — `display_image`, `display_compare_files`, an image dropped or pasted into a prompt or a terminal | anywhere, copied in if it is not already in the checkout | yes |

The containment rule is real, but it is a rule about **what may leave over the wire**, and it was
being enforced at *admission*. Membership in this list is precisely the allowlist
`handleAttachment` resolves against — `RemoteInboundPolicy.acceptsRepositoryPath` is only a
length-and-NUL check — so without containment a single `find ~ -name '*.png'` printed in a
terminal would enumerate the user's pictures into a remotely fetchable list. That is why *scanned*
paths still may not leave the checkout: text is not a handoff, and a build log, a `cat`, or a
repository's own fixtures can name any path on disk.

Terminal scanning has two complementary views of the same output. The live observer reads a
bounded logical-buffer suffix: SwiftTerm joins emulator-owned soft wraps and keeps real line
breaks, so narrowing or resizing the terminal cannot split a shell-printed path. Full-screen
agent TUIs have a second shape the emulator cannot solve: they often wrap markdown themselves
and paint each visual row with cursor movement, so every row is structurally independent in the
terminal buffer. On a reported terminal-turn boundary, Claude and Codex therefore scan the
bounded tail of their provider transcript off-main, through `TranscriptReplay`'s normalization,
and admit only assistant text from the newest turn. Tool results, reasoning, response-item
duplicates and older turns do not enter that scan. Stability retries cover the hook arriving
before the transcript's final record is flushed; source-path dedupe keeps those retries from
recopying or reordering a file. Codex's hook supplies the exact immutable rollout path; if hooks
are absent, the fallback session-tree lookup runs off-main rather than putting externally growing
filesystem work on the activity callback. Grok, OpenCode and ordinary shell output keep the
logical-buffer path until they expose an equally authoritative transcript reader.

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

Two consequences worth keeping for ordinary declared and scanned attachments:

- **The dedupe key is the source path, not the row's own path.** A copy's path is minted per
  attachment, so matching on it would file every regenerated chart as a new row. A second
  declaration of the same source keeps the row's slot — and therefore its identity on the remote
  wire — and overwrites the bytes underneath it. The immutable capture door used by
  `display_image` and `display_html` deliberately bypasses this dedupe.
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

The General page builds those toggles from `AgentKind.allCases`, the same closed set used by the
stored disabled set and scanner consumers. This is load-bearing because the empty pane directs a
user to that page by runtime name: a runtime with a setting but no row would give a precise route
to a control that did not exist.

### Acting on a row

The pane's four buttons act on the *selected* file, which is everything a pane holding one preview
can offer. A row's own menu (`ThemedTableView.onContextMenu`, the hook `ThemedOutlineView` already
had) says the same four for the row actually pointed at, and adds the one thing no button under a
single preview can: **another row's name**. Secondary-click opens it, `accessibilityPerformShowMenu`
is its pointerless twin, and the click also *selects* — the preview below is what "this file" means
in this pane, so a menu acting on one row while the picture under it shows another is the pane
disagreeing with itself in front of the user. Items capture the attachment they were built for, the
file tree's rule: a menu left open cannot act on a list that changed underneath it.
`contextMenuEntries(for:)` is where the decisions live, apart from the presentation, because
presenting a real dropdown needs a key window and the rules do not.

**A comparison is between two of the session's own pictures, and `AttachmentComparison` is the one
place that decides which and in what order.** Three surfaces ask — the submenu, a row dragged onto
a row, a picture dragged in from outside — and a menu that offers a pair the drop refuses is one
defect said twice.

- **Images only.** That is `CompareViewController`'s own rule read back rather than a second one:
  it classifies a pair from the bytes, and a PDF is binary, so every comparison offered for a PDF
  row would open a tab saying it cannot draw one. A PDF is therefore neither a name in the submenu
  nor a drop target — absent, not disabled, per the design system's rule for an offer that is
  always dead.
- **The clock decides the direction, not the gesture.** `ordered(_:_:in:)` puts the older file on
  the left whichever way the pair was named. A wipe travels old → new, so ordering by the drag would
  make the same pair read backwards depending on which row the pointer started from — an arrow
  claiming this morning's screenshot replaced this afternoon's. The list is a chronology and a
  comparison drawn from it is a chronology of two. **The clock alone is not enough, because ties are
  the common case**: both of the store's doors stamp one `timestamp` for a whole batch
  (`record(urls:)`, `record(declared:)`, `admitOutsideProject`), so two pictures from one terminal
  scan — or one `display_compare_files` — carry the same instant, and `<=` handed the decision back
  to the gesture. A tie falls back to the list's own order (a later row is the older picture) and
  then to the id, so the answer cannot depend on which row the drag started from. A fixture whose
  timestamps are seconds apart never sees this; `SessionAttachmentComparisonTests` records a real
  batch.
- **The submenu is built from the unfiltered list.** All / Agent / You is a convenience about
  provenance, and "how does the one I sent differ from the one it made" is precisely the question
  filtering it would make unanswerable.

The pane hands the pair to `onCompare`, a closure the display pane wires to its own
`addCompareTab` — so a comparison asked for twice reuses the tab that already holds the pair,
exactly as an agent's `display_compare_files` does. A closure rather than a walk up to the parent:
placing a tab is the panel's decision, and a list that knew how would need a whole panel to be
tested.

**Every drop lands *on* a row.** There is no order to insert into — the list is a chronology, and
not the user's to rewrite — so the only question a drop can answer is *which picture, against
which*. A pointer AppKit proposes between two rows is retargeted (`setDropRow`) to the nearer of
them rather than refused, which is what makes a 42-point row a target anyone can hit.

- **Rows are drag sources** (`pasteboardWriterForRow`), so a row also drags out to Finder or into
  a composer. That the file URL is on the pasteboard is what makes "a file cannot be compared with
  itself" **one** rule instead of two: the same picture dragged in from Finder is the same picture,
  and the check is `matches(_:path:)` against the target rather than a remembered row index.
- **A picture from outside is filed before it is compared**, through `PromptAttachment.record` —
  the same door a picture dropped on a composer goes through, so it lands as `user` and, from
  outside the checkout, is copied into custody. Not incidental: a Compare tab is persisted by path,
  and a screenshot dragged out of Preview lives in a directory macOS will reap, so a comparison
  drawn against a bare reference would come back empty some morning. It also puts the picture into
  the list it was dropped on, which is where anyone would look for it next. A file that is *already
  listed* is handed back as it stands only when its row is a **reference** — then the row and the
  drag name the same current bytes. A row that is a custody **copy** is re-declared instead, because
  custody froze its bytes when it took them: a chart regenerated at the same path since would
  otherwise be compared as it was that morning, and the store's dedupe-by-source rule refreshes the
  copy in its own slot.
- **Validation may not write anything.** `AttachmentComparisonDrop.canRead` answers from the
  pasteboard alone; `PromptAttachment.paths`, which writes a fileless picture to disk, is reached
  only from `acceptDrop`. A drag is answered on every frame of the pointer's travel, and the other
  way round is a file per frame. The two must also answer in the same *order*: `paths`
  short-circuits on any file URL and never looks at the bitmap beside it, so `canRead` asks
  `carriesFiles` first and only falls back to pixels when there are none — a text file dragged out
  of Mail with a picture preview attached otherwise lit a row up and then filed nothing. The temp
  file a fileless drop mints is deleted once its bytes are in custody, guarded on both the minted
  name and custody having been taken; the composer keeps its own because a CLI is about to be
  handed that path.
- **The validation is asked again at the drop.** `acceptDrop` re-runs `canDrop` rather than
  trusting the `validateDrop` that lit the row up: a terminal scan's debounce is a main-queue timer
  and event tracking is a common run-loop mode, so an attachment recorded mid-drag inserts at the
  top and slides every row down one — landing the release on the row *above* the one that said
  "Drop to compare", and on a dead-end binary comparison if that row is a PDF.
- **The row draws the drop, not AppKit** (`draggingDestinationFeedbackStyle = .none`), and it takes
  two views to do it: the **row** carries the wash, because that is the surface that draws selection
  and the two have to be one shape (`ThemedTableRowView.isDropTarget`, see
  [`design-system.md`](design-system.md) — drawn from the *cell* it was a plate visibly narrower
  than the selection stacked above it and exactly as tall, reported as looking odd); the **cell**
  carries the sentence, because the labels are its (`SessionAttachmentRowView.isDropTarget`).
  A ring answers *here*, which is the part the pointer
  already said; what makes an unfamiliar gesture learnable is the sentence, so the row's *secondary*
  line — the path, the one line nobody reads mid-drag — becomes **Drop to compare** in the accent,
  and takes its own text back when the pointer leaves. **Only that line.** The first version said
  the sentence by replacing the row: thumbnail and name gave their place to a saturated
  `accentMuted` plate under a full-accent ring, so the list opened a hole exactly where the picture
  you were aiming at had been, and a pointer affordance drew louder than the selection the user had
  chosen two rows above it — visible in a picture and in no assertion anyone would have written,
  which is what `testRendersTheDropAffordance` exists for. The wash is now
  `Design.Surface.dropTarget`, the third of the accent-at-16% family beside `searchMatch` and
  `annotationTarget` and held back for the same reason: it covers a row that still has to be read.
  No border, following the tab strip's own drop band — "a quiet wash, nothing louder". The mark is
  raised on one row at a time from a held index, because a drag reports continuously and hiding
  four labels on every visible row sixty times a second is a list relaying itself under the
  pointer. `ThemedTableView.onDraggingExited` exists for the other half of that: AppKit tells the
  *view* that a drag left or ended and the delegate neither, so a list drawing its own affordance
  would otherwise leave it lit on the last row crossed.

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
