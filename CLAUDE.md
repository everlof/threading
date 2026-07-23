# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Skalman is a native macOS app for organizing coding-agent sessions, built with **Swift** and **AppKit**, using **SwiftTerm** for terminal emulation. Targets **macOS 13+**.

A single window pairs a project sidebar with the selected session's terminal. Each session
hosts a Claude Code or Codex process inside a project folder, with a shell available under it
on demand. Sessions outlive their
terminals: when the agent exits, the PTY is torn down but the session record remains so the
conversation can be resumed later by its agent-assigned identifier.

## Build & Run Commands

The project is **Xcode-only** — a single `Skalman.xcodeproj`, no SwiftPM manifest. (SwiftTerm
stays a local Swift package that the Xcode project references; the app's own `Package.swift` was
removed so there is one build system, not two.)

```bash
# Build the app
xcodebuild -project Skalman.xcodeproj -scheme Skalman -configuration Debug build

# Run the tests (SkalmanTests target, hosted in the app)
xcodebuild -project Skalman.xcodeproj -scheme Skalman -destination 'platform=macOS' test

# Run the built app (never the bare binary — build with xcodebuild, then open the bundle)
open "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Skalman-*/Build/Products/Debug/Skalman.app | head -1)"
```

Resources: files under `Sources/` are members of the app target automatically (Xcode 16
synchronized folders). The asset catalogue compiles to `Assets.car`; `Resources/Icons` is marked
an explicit folder so its loose PNGs land under `Contents/Resources/Icons/`, loaded via
`Bundle.main` (`AgentBrandIcon`). Unit tests `@testable import Skalman`, so the test bundle is
hosted in the app; `AppDelegate` skips its real startup under `XCTestCase` so tests spawn no
agents or MCP server.

**`Tests/SkalmanTests` is *not* a synchronized folder** — a new test file must be registered
in `project.pbxproj` by hand (PBXFileReference, PBXBuildFile, the Tests group, and the test
target's Sources phase; follow the `A1000000…1`/`…2` id convention already there). The failure
mode is silent: an unregistered test file builds nothing and `xcodebuild test` reports
"Executed 0 tests" for it.

## Dependencies

- **SwiftTerm** (local fork): Terminal emulation engine handling VT100/xterm, ANSI parsing, PTY communication
  - Location: `./SwiftTerm/` (git submodule)
  - Upstream: https://github.com/migueldeicaza/SwiftTerm
  - **This is our fork** - feel free to modify SwiftTerm source code directly to implement features or fix bugs. The iOS folder is excluded on macOS builds.

## Architecture

### Core Components

- **LocalProcessTerminalView**: SwiftTerm's AppKit view that combines terminal rendering + PTY handling
- **EmojiFixedTerminalView**: Subclass that fixes emoji rendering with proper background compositing
- **TerminalSession**: Manages SwiftTerm view lifecycle, the child process, and session state
- **MainWindowController**: The single window; sidebar, terminal and display panes in an `NSSplitViewController`
- **ProjectSidebarViewController**: Source list of projects and their sessions
- **TerminalContainerViewController**: Swaps the terminal pane to the selected session
- **AgentSessionViewController**: Hosts one session's terminal and drives its launch/exit
- **DisplayPaneController**: The third pane, holding per-session content agents display
- **TerminalProfile**: User preferences for font, colors, shell configuration

### Model & Runtime Split

- **ProjectStore**: Owns projects and sessions; persists to `projects.json`. Knows nothing
  about running processes. Terminal-title updates are coalesced (`scheduleSave`) because
  agents rewrite the title constantly; structural edits save immediately.
- **AppSettings / AccountPreferencesStore**: `UserDefaults`-backed behavioural settings and
  per-account icon/name customisation.
- **AgentRuntime**: Caches live `AgentSessionViewController`s keyed by session id. A session
  with no entry is dormant.
- **AgentLauncher**: Builds the command line for a fresh launch vs. a resume, including
  account routing.
- **CodexSessionDiscovery**: Recovers the session id Codex assigns itself after launch.
- **AgentAccountDiscovery**: Finds agent logins by scanning `~/.claude-*` / `~/.codex-*`.
- **ShellAliasReader**: Labels accounts with the user's own alias name.

### Window Chrome

The window uses `.fullSizeContentView` with a transparent, hidden title bar, so the sidebar
runs the full height and the traffic lights float over it. The window title stays `Skalman`,
since it is only surfaced where macOS names the window (Mission Control, the Window menu).

Chrome is a real `NSToolbar` (`.unifiedCompact` style — the large `.unified` style sizes the
system sidebar toggle for a 15pt window title, dwarfing the quiet 13pt session title beside
it; see `MainWindowToolbar.swift`) rather than a
hand-rolled header. That matters: an earlier custom header had to track the sidebar's collapse
state and shift itself sideways to dodge the traffic lights. The toolbar gets all of that for
free, because its items are positioned relative to the window rather than to either pane.

- `.toggleSidebar` and `.sidebarTrackingSeparator` are **system** items. The first drives the
  split view's first item; the second keeps a divider aligned with the split position.
- `.sessionTitle` is ours, holding `SessionTitleItemView`. It sets `isBordered = false`, or the
  system draws a bezel behind it and it reads as a button.

Nothing may pin to `view.topAnchor` in either pane, or it lands under the toolbar — a bug this
project has already had once, where it hid the terminal's first rows. The terminal, placeholder
and sidebar content all pin to `safeAreaLayoutGuide`, which the toolbar insets for them.

`SidebarSplitViewController` overrides `toggleSidebar(_:)` to set `isCollapsed` directly.
The stock implementation collapses but does not restore here, which left no way back to the
sidebar. Overriding it fixes the toolbar button and the View menu together, since both route
through that one method.

Sidebar rows deliberately leave `NSTableCellView.textField` unset. Assigning it lets the table
restyle the label on selection, which tints an unemphasized source-list row with the accent
colour; the filled selection shape is the only cue wanted. Each row view's `applyTextColors`
owns the colours instead, inverting only for `.emphasized` (selected while the sidebar has
focus).

A session row's trailing edge is one fixed-size slot holding the status indicator and the
`⋯` actions button overlaid, crossfaded on hover via `alphaValue` rather than `isHidden` —
a stack view detaches hidden arranged views, so toggling visibility would re-lay out the row
under the pointer.

### MCP Server

Skalman hosts an MCP server and registers it with each Claude or Codex session it launches,
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

Three deliberate choices in the launch line:

- **The display tool is pre-approved** with `--allowedTools mcp__skalman__*` for Claude and a
  tool-specific `approval_mode="approve"` override for Codex, or every image raises a
  permission prompt and the feature costs more attention than it saves. Other tools are
  unaffected.
- **No `--strict-mcp-config`**, which would suppress the user's own MCP servers for every
  session Skalman launches — a far larger change than adding one.
- **The `instructions` field of the `initialize` response** carries the "you have a panel,
  prefer it over describing a file" guidance. Capability alone does not change behaviour: an
  agent in a terminal has no reason to believe anything it emits can be seen as an image.
  Both clients consume those server instructions, so a separate system-prompt flag is not
  needed.

Tool results are **plain text, never image content blocks**. The app has already drawn the
image, so the result costs a sentence rather than an image's worth of tokens — and it sidesteps
the undocumented question of what Claude Code does with an image returned from a tool.

### Display Panel

`DisplayContent.Body` is an enum, so the panel shows either an `NSImageView` or a `WKWebView`
and the `⋯` menu offers only the actions that fit — an image and a document share almost
nothing worth acting on.

Three things were measured rather than assumed, each having first been wrong:

- **`NSSplitView.setPosition` does nothing** under `NSSplitViewController`, which lays its
  items out with Auto Layout. `setPosition(915, ofDividerAt: 1)` left the pane at its 260pt
  minimum. Width is set with a temporary constraint, released once honoured so the divider
  stays draggable.
- **`NSImageView`'s intrinsic content size is the image's own size**, so left alone it drives
  the split view and a 900px image opens a 900pt panel. Both content priorities are floored.
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

`MCPServer` calls its handler on the main queue, because neither `ProjectStore`, `AgentRuntime`
nor AppKit is thread-safe. Everything arriving off the network hops before touching them.

The listener must be ready before any launch, since a launch reads the port — so
`AppDelegate` defers `restoreSelectedSession()` to the `start` callback. That callback fires
whether the listener came up or not: a failed server costs sessions their panel, not their
launch (`mcpFlags` returns "" and the command line is unchanged).

### Native Conversations (experimental)

A session can be rendered by Skalman instead of shown as a terminal. `AgentSession.usesNativeUI`
picks the surface, chosen at creation and **switchable afterwards** from the session row's `⋯`
menu ("Show as Conversation" / "Show as Terminal").

The switch was believed impossible for most of this project's life — the two surfaces were
assumed to drive the CLI in incompatible ways — and the assumption was never tested. It is
wrong. They drive *one* conversation: both resume by the session's own id, and both append to
the same transcript. Measured on Claude 2.1.217, a session created by `-p --session-id`
resumed in the interactive TUI with its context intact (the TUI redrew the headless turn
itself), resumed back into `--print` quoting the terminal turn verbatim, and again into
`--input-format stream-json` — the transport the native surface actually uses — echoing the
same `session_id`. One file throughout, growing 14 KB → 21 KB → 26 KB, and every record
carrying that one id: nothing in a transcript records which surface wrote a turn, so
`TranscriptReplay` cannot tell and does not need to. `--fork-session` exists to opt *into* a
new id, which is what makes plain `--resume` keeping it a guarantee rather than an accident.

Two constraints survive, and the implementation is shaped by them:

- **One live process per id.** Both surfaces append to the same transcript, so the switch
  discards the running one before the new one resumes (`AgentRuntime.discard`, then
  `ProjectStore.setUsesNativeUI`, then `TerminalContainerViewController.reopenIfShowing`).
  A session that is not on screen is only flipped; it opens on its new surface when next
  selected.
- **The permission models differ**, which is the real asymmetry rather than the session id:
  the terminal asks the user, while `--print` silently *blocks* tools unless the `PreToolUse`
  hook brokers them. A session switched into the native surface therefore needs its hook
  settings file in place at relaunch, which is the same file a natively-created session gets.

Codex is *not* covered by that measurement — only Claude was probed — so its behaviour on a
switch is inference from a shared design, not evidence.

The mode is gated behind `AgentKind.supportsNativeUI`, which now admits every kind — it stayed
a property rather than being deleted with its call sites, because an agent without a structured
transport would need it back and the branches reading it are the honest place to notice.

**Claude was gated off here for most of this project's life, and no longer is.** The reason it
was disabled — `claude -p` runs on the user's subscription, and Anthropic's terms reserved
subscription OAuth for Claude Code and claude.ai — described the February 2026 wording
accurately and has since been overtaken. The current policy targets *routing requests through
subscription credentials on behalf of users*: offering Claude.ai login inside your product, or
lifting the OAuth token out of `~/.claude` and calling the API while impersonating Claude Code.
Skalman does neither. It spawns the user's own installed `claude` binary, which authenticates
itself from whatever `claude auth login` put on disk, and Anthropic's help centre now names
`claude -p` and third-party apps built on that transport as subscription-drawing usage.

The unresolved part is economic, not legal: a June 2026 plan to move `claude -p` and Agent SDK
turns onto separate metered credits at API rates was withdrawn on the day it was to take effect,
explicitly as a pause. If it returns, native Claude sessions cost differently from terminal ones
— worth surfacing to the user then, but not a reason to keep the surface unreachable now.

```
                    ConversationStreamSession
                              │
            ┌─────────────────┴─────────────────┐
            ▼                                   ▼
 CodexStreamSession                    ClaudeStreamSession
 one child per turn                    persistent stream
 codex exec --json                     claude --print --stream-json
            │
            ▼
 ConversationViewController
```

`codex exec --json` is one-shot, not a persistent input stream. `CodexStreamSession` is
therefore a **logical** long-lived session: `start()` makes it ready, `send()` launches a child,
and a normal child exit makes it ready again. The first child creates a thread; the
`thread.started` event supplies the id persisted in `AgentSession.agentSessionID`, and each
later plan becomes `codex exec resume <id> --json -`. Plans are rebuilt per turn from the latest
`ProjectStore` record so the newly adopted id is never trapped in the controller's old snapshot.

`CodexStreamEvent` maps provider-specific JSONL onto the existing `[StreamEvent]` rendering
model. `agent_message` items become markdown, command/MCP/search/file items become the same
collapsible tool rows as Claude calls, and `turn.completed` returns the composer to Ready.
Codex does not emit agent-message deltas through `exec --json`, so its messages land complete;
the streaming placeholder earns its keep only on the Claude transport.

The Claude transport was measured around four constraints before it was written, and re-probed
against CLI 2.1.217 before the gate was opened — the flags, the multi-turn persistence and the
carried context all still hold:

- **The process survives multiple turns.** One instance serves a whole conversation; it is not
  respawned per message.
- **Token-level streaming exists** (`content_block_delta`), so this is not just transcript
  tailing with extra steps.
- **There is no interactive permission prompt.** A headless run silently *blocks* tools it
  would otherwise ask about — the third turn of the probe tried to write a file and was
  refused outright.
- **A `PreToolUse` hook can broker it.** The hook receives `tool_name`/`tool_input`, blocks
  synchronously while the app asks, and its `permissionDecision` is honoured.

That last point made the Claude mode viable rather than a choice between useless and unsafe.
The hook is a bare `curl` reading stdin and writing stdout, which is exactly the command-hook
contract — no helper script to install or keep in step with the app. It posts to the *existing*
MCP listener, and `session_id` routing was already solved, because for Claude sessions that
identifier is the UUID Skalman minted.

For the Claude transport, the request is shown **inline in the conversation that
raised it**, as a `PermissionRequestView` card (`ConversationViewController.presentPermission`),
not a window-modal sheet. A sheet was the wrong shape: it seized the whole window for a decision
belonging to one session and gave no clue which session asked when several were running. The card
sits in the thread, keeps its place as a record of what was chosen after it is answered, and
carries the edit diff for edits. The modal sheet survives only as a fallback for the impossible
case — a request with no live conversation.

Claude requests are shown **one at a time**: an agent can fire several tool calls in a turn, but
a stack of cards is answered out of context, so they queue and the next appears only once the
current one is decided (`permissionQueue` / `activePermissionCard`, `showNextPermissionIfIdle`).

A pending Claude request in an **off-screen** session raises the sidebar's attention dot: a
native session reports `activity` through `AgentRuntime` alongside terminal sessions, returning
`.needsAttention` when anything is waiting and the session is not visible (`isVisible`, set by
`setVisibleSession`). On screen the card is the cue, so no dot. `terminate()` denies the active
card and every queued request, so a session that goes away does not leave the CLI blocked on the
hook's timeout.

`PermissionPolicy` decides which Claude tools are worth interrupting for, in Swift rather than
in the hook's matcher: the hook fires for every tool and the app filters. The read-only set is a short
**allowlist**, so a tool added in a future release prompts rather than slipping through unasked.

Claude's two views come from the CLI: `stream_event` deltas while tokens arrive, and complete
`assistant`/`user` messages once each finishes. The finished message is authoritative — the
streaming label is thrown away and replaced when it lands, rather than reconstructing state
from deltas.

**Resuming replays the transcript.** Neither agent streams old context into a new process, so
without `TranscriptReplay` the agent remembers a conversation the screen does not show. The
terminal never needed this: its scrollback *was* the record. Drawing the conversation ourselves
means rebuilding it.

Replay emits `[StreamEvent]` rather than a parallel model, so replayed and live content share
one rendering path. Claude reuses its content-block parser; Codex reads the clean `event_msg`
user/agent records from its rollout and deliberately ignores duplicate `response_item`
messages. `.userMessage` exists only for replay: a live turn is echoed locally as it is sent,
so producing it from the stream too would draw it twice.

Three Claude record kinds are skipped, and each would otherwise read as nonsense: `isMeta` (text the
CLI injected on the user's behalf, never typed), `isSidechain` (subagent threads, which belong
to a Task run rather than this conversation), and everything that is not `user`/`assistant`
(mode changes, titles, file snapshots). The cap is a *rolling window* keeping the newest turns
— what matters about a conversation being resumed is how it ended.

### Conversation Rendering

Two things about the conversation's *appearance* were changed by looking at rendered fixtures
rather than by reasoning about single rows, because both are properties of a page rather than
of a row:

- **A tool row has no fill at rest** (`Design.Chat.toolRowResting` is `.clear`; hover or
  expansion raises `toolRowActive`). A working turn is mostly tool rows — a real rollout ran
  twenty consecutively — and twenty filled slabs read as the conversation's content rather
  than as the record of what was done, burying the sentences between them. This is the design
  system's own "quiet until relevant" rule, applied where it was most needed. Hover matters
  more than usual here: with no fill, it is the only thing saying the row can be clicked.
- **A rule separates turns** (`ConversationRowView.turnDivider`, above each user turn but not
  the first), and `turnSpacing` went 16 → 30. Spacing alone was tried first and was not
  enough: the rows on either side of the gap are themselves separated by space, so a bigger
  gap reads as a bigger gap rather than as a boundary.

### The Turn Rail

`ConversationMinimapView` is a contents page for the conversation: one mark per exchange down
the gutter, hovering one previews what was asked and what came of it
(`ConversationTurnPreview`), clicking jumps to it. Turns currently on screen brighten, so it
answers "where am I" as well as "what is here". The idea, the fisheye taper and the
disappear-rather-than-crowd rule are t3code's `MessagesTimeline` minimap, and Codex ships the
same pattern.

**The column cap is what makes it possible, and was worth doing anyway.** The conversation ran
the full pane — 900pt of unbroken measure in a wide window, which `Design.Size.readableWidth`
already exists to prevent and which the composer already respects. Capping it at 620 and
centring it fixes the measure *and* leaves the gutter the rail lives in. Two problems, one
change; the rail was blocked by a layout that was independently wrong.

`ConversationMinimap` holds the arithmetic, separately from the view, because the two rules
worth protecting are invisible in a screenshot of a wide window:

- **It indexes, it does not scale.** Marks are evenly spaced — a turn that ran forty tool calls
  and one that ran none are one exchange each, and spacing by length would give the long one a
  stretch of rail that says nothing about how much was *said*.
- **It vanishes rather than crowd the text.** `railWidth` returns zero when the pane is too
  narrow for a gutter, and the view hides. Skalman is a three-pane window and the conversation
  is routinely the narrow one, so this is the common case rather than the edge case — the same
  rule t3code encodes, arrived at for the same reason.
- **It belongs to the pane, not to the column** (`railLeading`). Anchored to the column's
  leading edge it looked right at 1000pt and wrong at 2000: the column is centred, so the rail
  drifted inward with it and ended up stranded mid-margin, attached to nothing the eye can
  see. It rests at `Design.Spacing.pane` from the pane's own edge and gives that up only when
  the gutter cannot hold both — clearance from the text is the one thing it never trades.

That last one was found by *running the app*, not by the harness, which had only been asked
for widths where the answer was not yet obviously wrong. The pane renders now include 1800pt
for that reason, and a test walks every width from 320 to 2600 checking the rail neither
leaves the pane nor comes within `gutterInset` of the column.

Marker spacing is 20, not t3code's 8: at three turns theirs is a 16pt smudge that reads as a
rendering artefact. Measured off Codex's own rail — about twenty-five marks over five hundred
points — and checked by rendering it.

**The model is separate from the drawing.** `ConversationTimeline` folds `[StreamEvent]` into
`[Row]` and reports what changed; `ConversationRowView` turns one row into one view;
`ConversationRendering` places it. This is t3code's `MessagesTimeline.logic.ts` /
`MessagesTimeline.tsx` split, in Swift — their idea, and worth naming as theirs.

It is **incremental, not a fold**: `apply` takes one event and returns only the changes, because
the same type serves a live stream and a replay, and recomputing every row per token would make
streaming quadratic. Replay is `apply` in a loop.

The split exists because the interesting decisions — what a tool call's one-line subject is,
which result attaches to which call, when a streamed placeholder is discarded — were previously
reachable only by standing up AppKit and reading a view tree, so none of them were tested and
several were wrong.

**Fixtures are real conversations, scrubbed** (`Tests/Fixtures/Transcripts`,
`scripts/scrub_transcript.py`). The scrubber replaces content and preserves *shape*: JSON keys,
markdown structure, patch envelopes, escape sequences, and argument names all survive, because
those are what the parsers read. Substitution is a deterministic per-token map, so an `Edit`'s
`old_string` and `new_string` still differ in exactly the lines they differed in and `EditDiff`
sees a real diff. Windows are chosen by a **coverage score** rather than taken from the top — a
conversation's tool variety is not evenly spread, and the first window that started on a user
turn contained no `Edit` at all.

Three scrubber bugs each produced a fixture that exercised a schema no CLI emits, and each was
found by auditing output rather than by reading the writer: JSON object *keys* are sometimes
file paths, arguments are sometimes a *string* of JSON, and Codex's `exec` wrapper is a line of
JavaScript where argument names appear as identifiers and `\n` is an escape.

`ConversationRenderTests` draws whole fixture conversations through the real views and writes
them out as PNGs, light and dark (`SKALMAN_RENDER_OUT` to redirect). **This is what makes the
appearance reviewable at all** — and it immediately paid for itself: rendering a Codex rollout
showed twenty identical `$ Bash` rows with no command beside any of them. Codex names its
arguments differently from Claude (`cmd`, not `command`; a patch instead of `old_string`), so
`TranscriptReplay.normalised` now translates them, `CodexPatch` reads the `*** Begin Patch`
envelope into `[DiffLine]`, and `PermissionRequest.summary` falls back to *any* descriptive
argument rather than dumping JSON. Every one of those was a correct parser with the wrong
vocabulary, which no parser test could see.

**Claude's reasoning cannot be replayed.** The CLI writes a `thinking` block per reasoning turn
but strips its text, keeping only the `signature` — measured at 4451 blocks across the 120 most
recent transcripts here, of which 65 carried any text. Codex's `agent_reasoning` replays in
full. The asymmetry is the CLIs', not ours, and is pinned by a test so that a release which
starts persisting the text fails loudly rather than going unnoticed.

The test target is **not** a synchronized folder — it carries an explicit file list, so a new
test file compiles nowhere and reports nothing unless added to it. `scripts/add_test_file.py`
does the four edits.

The chat surface follows the shape of a modern chat client, not a log: the user's turns are
right-aligned bubbles (`appendUserBubble`), the agent's are left-aligned markdown
(`appendAssistant` → `MarkdownView`). A bubble suits a short instruction; flowing text suits a
long answer, and forcing either into the other's shape is what made the first pass read as a
debug dump.

`Markdown` is a hand-written CommonMark subset — headings, paragraphs, fenced code, simple
lists, inline emphasis and code spans — because the project depends only on SwiftTerm and this
is a hundred lines of scanning rather than a package to track. Parsing is a **reader table**:
each block kind is a function that either consumes its block or returns nil for the next reader
to try, which keeps `parse` a flat loop rather than a branching tower. Fenced code is read
first and verbatim, so a `*` in a shell glob is never mistaken for emphasis. Code blocks draw
on their own scrollable monospace surface; everything else is a selectable label, so wrapping
and selection come free.

Tool calls render through `ToolCallView`: a fixed-width **glyph column** (`$` bash, `→` read,
`←` write, `✱` grep/glob, `◈` search — the vocabulary a terminal user already knows), the
tool, its one-line subject, and a size once the result lands. Collapsed by default and clicked
open, because a directory listing is longer than everything said around it. The glyph and the
whole surface aren't inspiration taken loosely from opencode's TUI — they are its exact idea,
expressed in AppKit and system colours instead of a hardcoded palette, per this file's
design-system rule.

Streaming stays plain text replaced by rendered markdown when the message finishes: rendering
markdown per token would reflow the whole block on every keystroke, and the finished message is
authoritative anyway. This is the same "finished message wins" rule the live/replay split
already depends on.

An **edit tool renders a diff**, not raw output. `EditDiff` builds `[DiffLine]` from the call's
own arguments — `Edit` gives old/new text, `Write` a whole new file (all added), `MultiEdit` a
list of hunks — so the diff is known *before the tool runs* and the result only confirms it
landed. The alignment is a line-level LCS walk, skipped past `alignmentCap` lines for a plain
removed-then-added rendering rather than paying for a huge table. `DiffView` draws one
full-width coloured row per line (the width is what reads as a diff, so it is rows, not an
attributed string) with a `+`/`−` gutter; long lines wrap because the pane is narrow and hiding
half a change off the right edge is worse. The same `DiffView` is the approval sheet's
accessory: an edit is approved on *what* it changes, which the sheet now shows, not merely which
file. This is opencode's diff-viewer idea in AppKit and system colours.

`JSONLReader` and `ClaudeTranscript` were extracted rather than copied: `SessionImporter`
already read these files, and the transcript path was already derived in two places. The
reader's correctness notes — never cap a record, let the caller decide when to stop — now live
in one place instead of being rediscovered per caller.

### Reclaimable Storage

`ArtifactScanner` finds build output a project can rebuild, and the Storage settings page
removes it. On the machine it was built for: **87.61 GB across 45 directories**, and 58 GB of
that in git worktrees rather than the checkouts anyone opens — abandoned branches each holding
a full `target/` and their own copy of `node_modules`.

**Two gates decide, and neither alone is enough.** A path is offered only when git considers it
disposable *and* its directory name plus an ecosystem marker identify it as known build output.

- Ignore status alone is the tempting rule, and it deletes your secrets: measured here,
  `git check-ignore` also says yes to `.env.local`, `.env.jira` and
  `ansible/runner-controller-secrets.yml`. It is *necessary* (the project does not keep this),
  never *sufficient*.
- The marker is not decoration either. `target`, `build` and `dist` are ordinary words; a
  `target` beside no `Cargo.toml` is somebody's data.
- **`check-ignore` answers about patterns, not tracking.** A committed directory matched by
  `.gitignore` still reports as ignored, because git's rule is that tracked files are unaffected
  by the ignore list. `ls-files` is therefore asked as well, and anything tracked inside refuses
  the whole directory. A test found this while being written, not a user.

Both gates are re-checked immediately before a delete: a listing being read is a listing going
stale. Removal is **immediate rather than to the Trash**, which for once is the safer-feeling
option that helps nobody — 30 GB in the Trash has not been reclaimed.

**Sizes count each inode once, the way `du` does.** Build directories are full of hard links —
one real Cargo `target/` held 37,810 files sharing 25,021 inodes — and summing per-file sizes
claimed 42.79 GB where the directory occupies 33.18 GiB, a 29% overstatement of the single
number the feature exists to report. The identifier is only fetched when `linkCount > 1`, so an
ordinary file costs nothing extra.

**Findings are cached and the scan is passive.** `ArtifactScanService` keeps the results in
Application Support and refreshes them on a `.background` queue — the QoS whose I/O the system
throttles, which is right for a chore nobody is waiting on. Finding 45 directories means walking
every *other* directory in four projects first, a little over a minute here, so a page that
scanned on open would be empty every time it opened. It draws the cache instead and asks for
anything stale to be re-measured. A passive pass skips a project whose sessions are **working**:
an agent mid-build is both the worst moment to compete for the disk and the worst moment to
measure a directory it is still writing. A cached number is shown with its age, because one that
does not say when it was taken is claiming to be live.

**Agents can see the listing and propose a cleanup, never perform one.** `list_reclaimable_storage`
returns the cache; `propose_storage_cleanup` puts named paths to the user as a sheet and removes
only what they approve. The gate that keeps this from being an arbitrary-delete primitive is that
**a proposal can only name paths already in the findings** — everything there has passed both of
the scanner's gates, and they are checked again at the moment of deletion. The tool answers only
once the user has decided, so the agent's next turn knows the outcome rather than assuming it.

**The instruction keys on the failure, not on a measurement.** An earlier version stated the disk's
free space in the `initialize` instructions, so an agent would know it was short. Wrong twice: the
reading is a snapshot taken at session start, while a session that fills the disk does so an hour
later — and an agent that runs out of room learns it from the write that failed, which is a better
signal than any advance warning. What it lacks at that moment is not the fact but the tool, which
is static. So the group's instruction triggers on the symptom ("No space left on device", ENOSPC,
a build dying partway) and tells it to look before reporting failure. `DiskSpace` survives for the
Storage page, where free space is the context that turns "87 GB reclaimable" into a decision.

The page groups **by checkout, not by project**, because six of one project's checkouts hold a
`web/node_modules` and a row reading `web/node_modules` under a heading reading `sonda` names
none of them. Each heading is `<project> · <worktree or branch> · <size>`; rows are relative to
their checkout. Rows state the rebuild command and the age, and a directory written in the last
fifteen minutes reads as **in use** — the first real scan found the largest directory on the
page had been written two minutes earlier, in a worktree with no Skalman session to warn about.
That is the second of two independent in-flight checks, the other being a running session in
the project.

### Git Layouts

`GitInfo` reads git metadata from disk rather than shelling out. Three layouts matter, and
only the first has a `.git` *directory*:

| Layout | `.git` | Metadata lives at |
|---|---|---|
| Ordinary checkout | directory | `<root>/.git` |
| Linked worktree | file | `<repo>/.git/worktrees/<name>` |
| Submodule | file | `<super>/.git/modules/<name>` |

Worktrees and submodules store a **file** containing `gitdir: <path>`, so reading
`<root>/.git/HEAD` finds nothing — worktrees showed no branch at all until `gitDirectory(for:)`
started following that pointer. A git *subtree* needs no handling: it is merged content, and
looks exactly like an ordinary subdirectory.

`worktreeLocation(for:)` resolves a path once into both identities, and the accessors
(`worktreeIdentity`, `repositoryIdentity`, `worktreeName`) read from it. The two identities are
the `git-dir` / `git-common-dir` distinction: `worktreeIdentity` is the checkout's own git
directory (`<repo>/.git/worktrees/<name>`, or `<repo>/.git` for the main tree) and is stable
per checkout — it does not change when the branch does; `repositoryIdentity` trims the
`/worktrees/<name>` suffix so every checkout of a repo shares one identity, which is the
sidebar's grouping key. **`worktreeIdentity` is the durable key for "which checkout"; the
branch is only ever a display value.** A submodule keeps its own identity under `/modules/`,
correctly — it is a separate repository that happens to live inside another.

The sidebar groups **only when a repository has more than one checkout added**, so the common
single-checkout case keeps the flatter two-level layout. Grouped checkouts are labelled by
branch, since the repository name is already shown above them.

A branch belongs to a *checkout*, not to a repository: two worktrees of one repo are on
different branches simultaneously. It is re-read when a session stops working, which is when
an agent is most likely to have just switched, rather than by polling.

The composer's branch chip therefore offers **checkouts, not branches**
(`ProjectStore.siblingCheckouts(of:)`): this checkout, any other added checkout of the same
repository, then `New Worktree…`. It listed the repository's whole `git branch` output once,
which invited picking a branch nothing was standing on — the session then ran in the origin
checkout anyway while its record claimed the branch that was asked for. A branch with no
checkout is not a place a session can run; making one is what the worktree item is for.

That item lives *in the menu* rather than in a chip of its own, where it read as a state —
one of the selected choices in the row — when it is an action. One control, one question:
which checkout does this session run in.

A *session*, though, carries its own branch record (`AgentSession.branch`): captured at
creation, re-read by `ProjectStore.refreshBranch` at the same stopped-working moment, and
frozen while dormant — a conversation happened on whatever was checked out at the time, and
that stays true after the checkout moves on. It drives the sidebar's **branch grouping**
(`SidebarTreeBuilder`, `BranchGroupNode`): inside a project, sessions sharing a branch gather
under a heading, but **only when that branch has more than one session** — the same
earns-its-level rule as repository grouping, applied one level down. Sessions on lone
branches or with no recorded branch stay directly under the project, and a group takes its
first session's position so the list keeps its order. Toggleable via
`AppSettings.groupsSessionsByBranch` (on by default; Settings > General), and also from where
the grouping is *seen*: a checked menu item in the project-row and branch-heading context
menus, and a gear that fades into a branch heading's trailing slot on hover (the session
rows' `⋯` crossfade mechanism, reused) opening the toggle plus an "All Settings…" door.
Branch headings are not selectable, collapse like projects (state kept in-memory only — the
groups themselves are transient), and the hover popover prefers the session's recorded branch
over the checkout's current one for the same reason the record exists.

The branch is **not shown on the project row** — it lived there once as a subtitle, which read
as though the project *were* that branch, when a checkout's branch changes and one repo can
have several checkouts at once. It surfaces instead in the **session rows' hover popover**
(`SessionInfoPopoverViewController`) — sessions are what get selected and what run inside the
checkout — alongside the session's full title, its agent and account, the folder path, and,
when the checkout is a linked worktree, `GitInfo.worktreeName`. The one place the branch still
names a row is a *grouped checkout*, where it is the row's identity — the repository name is
already above it, so the branch is what tells the checkouts apart. The popover opens after a
short hover dwell so it does not flash while the pointer crosses rows, and it survives the
constant reconfigures of a working session's row, dismissing only on exit or reuse for a
different session.

### Git Review

A per-session **Review** tab in the display pane (`GitReviewViewController`, hosted as
`DisplayTab.Body.review` — the browser's live-view-controller shape, reused). View menu ▸
Git Review, ⇧⌘R.

It was read-only for its first version and no longer is; what survives of that rule is the
line between *reversible* and not. `GitIndexWriter` is the whole of the write half — stage,
unstage, commit — and there is **no discard**, because every other action here is undone by
the control beside it while throwing away a change an agent just made is undone by nothing.

Six modes behind one chip, and the default is not one of opencode's five: **Uncommitted**
(HEAD vs worktree, staged + unstaged + untracked) is what a user actually asks after an agent
turn — agents rarely commit mid-task, and splitting that answer across Unstaged/Staged made
the common case two reads. Unstaged, Staged, Last Turn, Branch and Commit complete the set.
Branch diffs from `merge-base(default branch, HEAD)` **to the worktree**, so uncommitted work
counts — a branch's `+362 −26` should not shrink when work is merely unstaged. On the default
branch itself the merge-base is HEAD and the mode degrades to Uncommitted, which is honest.
Commit mode is the history browser: a paged `git log --numstat` list (100 a page), one commit
opened into its own diff with Back returning to the list.

The data layer (`GitReviewReader`) shells out on a dedicated queue and completes on main —
`GitWorktree`'s runner made async, following `ProjectIconResearch`'s shape. Every invocation
passes `--no-optional-locks`, so a *read never takes `index.lock`* out from under the agent
working in the same checkout, and `-c core.quotepath=false` so paths arrive literal. Diffs
add `--no-color --no-ext-diff --no-textconv`; parsing git's porcelain and unified-diff output
is `GitDiffParser`, pure functions with the fixture traps (C-quoted paths, the trailing tab
after a path with spaces, `\ No newline` markers, `-z` rename records) pinned by unit tests.

**`git diff` never mentions untracked files**, so the working-tree modes synthesize them:
`status --porcelain=v2 -z -uall` lists them individually and each becomes an all-added file
diff read in-process — not `diff --no-index` per file, which would spawn a process per file
in a freshly scaffolded project. Size-capped (256 KB), binary-sniffed by git's own NUL
heuristic.

**Last Turn's baseline is `git stash create`** — an unreferenced commit that mutates no ref,
no index, no worktree; empty output means clean, so HEAD is the baseline. Captured by
`GitTurnBaselineStore` on the *entering-working* edge (fed from the same
`sessionStateDidChange` hook that refreshes the branch), because a baseline taken at stop
would fold the user's own between-turn edits into the next turn. In-memory only: the snapshot
is gc-prunable, and a persisted hash whose object has vanished is a worse answer after
relaunch than "No turn recorded yet" — a pruned baseline is detected by `rev-parse --verify`
and reported as expired, not as an error. `stash create` omits untracked files, so the
baseline records the untracked path *set*: files untracked then and still untracked now are
not the turn's work. The residual gap — edits to a file already untracked at turn start —
shows only in Uncommitted, and that is accepted.

Rendering reuses the diff machinery: `DiffView` gained a second initializer for numbered
`GitDiffLine`s (one number column, new side falling back to old — a dual gutter spends a
narrow pane's width on bookkeeping) while the edit-tool path renders pixel-identically.
`GitReviewFileRow` is `ToolCallView`'s collapse pattern per file, and **bodies build on first
expand** — a collapsed file costs one header row, which is what bounds a multi-thousand-line
branch diff. Small files auto-expand (≤200 lines each, ≤600 cumulative). The mode persists
with the tab (`PersistedTab.mode`); restore builds the controller but runs no git until the
tab is actually shown, the browser's deferred-load rule.

**Staging is offered by two modes of six**, and the rule is not a UI preference: a patch
applies to the index only when the index is what the diff was measured *from*. Unstaged
(index → worktree) stages hunks, Staged (HEAD → index) unstages them by applying the same
patch `--reverse`, and Uncommitted (HEAD → worktree) can speak about whole files but not
hunks — its hunk offsets describe a baseline the index may already have moved past. Branch,
Last Turn and Commit compare things that are not the index at all. `GitStaging.capability(for:)`
holds it in one place; `GitPatch` rebuilds a one-hunk patch from the parsed model, since the
pane no longer has the bytes, and passes `\ No newline at end of file` through unprefixed —
dropping it silently re-adds a newline the file never had.

Reads and writes share `GitProcess`, which is where the pipe handling, the timeout and the
oversized-output guard live; the writes drop `--no-optional-locks`, because a write needs the
lock it is about to take. Losing that lock to the agent's own git is its own failure case
(`GitFailure.indexLocked`) rather than a generic error: the answer is to try again, not to
fix anything. The commit composer is a `PromptView`, and the message lives on the controller
rather than in it — staging re-reads the pane, which rebuilds the composer, so a message kept
in the view would be lost with every stage.

The tab **watches the checkout** (`GitCheckoutWatcher`, FSEvents) rather than polling. Two
paths are watched, since a linked worktree's `index` and `HEAD` live in
`<repo>/.git/worktrees/<name>` and its refs in `<repo>/.git/refs` — neither under the checkout.
`GitWatchFilter` is where the traps are and is pure, so they are tested: nearly everything a
git command writes is its own bookkeeping, `.lock` files are git announcing a write rather
than making one, and only `index`, `HEAD`, `refs/` and their kin mean the diff changed. This
is also the second reason `--no-optional-locks` matters: without it a read would refresh the
index, the watcher would see it, and the pane would re-read itself forever.

Auto-refresh forced two things that manual refresh never did. **The reader's place is kept** —
the scroll offset survives a reload of the same surface (a mode switch or an opened commit is
a different page and starts at the top), and `expansionOverrides` records what the user opened
or closed by hand so a re-read does not close what is being read. And a paged-into history or
an opened commit **does not follow the checkout** at all (`followsCheckout`): both are
immutable or append-only, so re-reading them costs the reader their place for nothing.

**Diffs are syntax highlighted** by `Syntax`, a hand-written lexer with a table of languages
(`SyntaxLanguages`) — the same reasoning as `Markdown`: a diff row needs a string told from a
comment, not a grammar, and the project depends only on SwiftTerm. An unknown extension
renders plain rather than guessed at, because a wrong guess colours half a line and reads as a
bug in the diff. State is carried down the **two sides separately**, since a diff interleaves
two versions of a file and one running state would let a `/*` deleted from the old side comment
out the new side. `Design.Syntax` has four hues and a dimming, and deliberately no red or
green: both already mean removed and added here, and a red string literal inside a green added
line says two contradictory things at once. Highlighting also changes the *base* colour —
highlighted code is label-coloured and leaves the wash and the gutter to say what happened to
the line — which is per view, not per row, so one file never mixes the two conventions. The
tool rows and permission cards feed the same `DiffView` with the path they are editing, so an
edit in a conversation is highlighted by the same table.

**The history draws a graph** (`GitCommitGraph`, `GitGraphRailView`). Lanes are assigned from
`%P` rather than by parsing `git log --graph`'s ASCII art, which is drawn for a fixed-width
terminal — reading pixels back out of it to draw them again is a lossy round trip through
someone else's renderer. A lane is a slot waiting for a particular commit: a commit takes the
lane waiting for it, its first parent inherits that lane, and every further parent opens a new
one, which is why a merge fans out downward and a branch converges upward. Free lanes are
reused leftmost so the graph stays narrow, and lanes waiting for parents beyond the page run
off the bottom honestly. The commit rows lost their fill and gained a hover to make room for
it: a rail broken once per row reads as a history that stops and restarts, so the list closes
its gaps, and a hundred filled slabs was the tool-row problem again anyway.

`NSTextField.label(attributed:)` exists because of a bug this work surfaced: a field created
empty measures itself empty, and assigning `attributedStringValue` afterwards changes what is
drawn without changing what was measured — so every `+N −M` counter in the pane was laying out
four points wide and drawing nothing. Assigning attributed text also turns wrapping back on,
and a wrapping field has no intrinsic *width* at all, which is what let Auto Layout squash it.
`GitReviewRenderTests` is what found it: the same fixture-to-PNG idea as the conversation
renders, for the same reason — a claim about colour on a coloured wash cannot be checked by
reading assertions about token ranges.

### Session Activity

`SessionActivityTracker` derives `dormant` / `idle` / `working` / `needsAttention` from PTY
output, because an idle agent writes nothing at all — measured at zero bytes over 19s while
sitting at its prompt. This works for any program rather than one specific agent.

Four guards keep it honest:

- A **byte threshold** (`workingByteThreshold`), so the terminal echoing typed characters is
  not mistaken for work.
- A **quiet interval**, so gaps within a burst of output do not flicker the state.
- A **resize quiet period** (`noteTerminalResized`). Resizing sends `SIGWINCH` and full-screen
  terminal apps answer by repainting everything, which is a large burst of output that we
  caused. Suppression blocks a session *entering* `working`, but deliberately keeps an
  already-working session's timer alive — otherwise resizing mid-task would report it as
  finished.
- A **scroll quiet period** (`noteScrollForwarded`). When a program tracks the mouse, wheel
  events are forwarded to it (see the fork's `MacTerminalView.scrollWheel`) and it answers
  each one by repainting its content — the same we-caused-it output as a resize, extended by
  every event so a momentum gesture stays covered.

`needsAttention` is only raised when work finishes in a session that is *not* on screen;
`AgentRuntime.setVisibleSession` tracks which that is. A terminal bell raises it directly.

Output arrives on the main queue (`LocalProcess` defaults its dispatch queue to
`DispatchQueue.main`), which is what lets the tracker use `Timer` safely.

**An agent that reports its own turns is believed instead.** All of the above is a proxy, and
the guards exist because it cannot tell thinking from repainting. Claude's own hooks say so
outright, so `AgentLauncher.claudeCommand` now writes a `--settings` file for *terminal*
sessions too — lifecycle hooks only, no `PreToolUse`, because a terminal session raises the
CLI's own permission prompt and intercepting it would replace a working prompt with a second
one. `UserPromptSubmit`, `Stop`, `Notification` and `SessionStart` curl back to the listener
(`MCPDefaults.lifecyclePathPrefix`), and `HookLifecycleRelay` hands each report to the session's
tracker. Verified end to end against CLI 2.1.217: the three ordinary events arrive in order,
carrying the prompt text.

Three things shape it, and each was wrong first or would have been:

- **The lifecycle endpoint never blocks**, unlike the permission one. These hooks fire on the
  agent's own turn boundaries, so any pause is latency before the user's prompt is answered, and
  nothing reads the reply — `routeLifecycle` responds `.accepted` before it parses the body, and
  the hook runs with a 2-second timeout.
- **The hook must stay silent.** Claude feeds a `UserPromptSubmit` hook's stdout back to the
  model as context and reads a failing `Stop` hook as a reason to keep going, so a lifecycle
  report that leaked either would change the conversation it only observes. Hence
  `>/dev/null 2>&1 || true`, which is load-bearing rather than tidy.
- **Reporting latches** (`reportsOwnActivity`), and output then stops driving the state at all.
  The two signals disagree by design: a working agent is quiet while it waits on the model and
  noisy after its turn ends while the CLI redraws its footer. Falling back per-event would
  flicker between them. `markRunning` clears the latch, because the settings file is written per
  launch and can fail — a latched tracker with no reports coming would sit idle forever.

`--settings` **layers rather than replaces** (measured: with one `SessionStart` in the file, two
`SessionStart` hooks fire — ours and the user's own), so this does not disable whatever the user
already has wired into their agents.

`Notification` is the one event with no Codex equivalent in 0.144.6, which is why
`HookLifecycleEvent.codexEventName` is optional and pinned by a test.

**Codex reports the same events, and everything hard about it follows from one difference:**
it has no `--settings` flag. Hooks live in `<CODEX_HOME>/hooks.json`, one file per *account*,
shared by every session — and owned by the user. Measured on 0.144.6: `codex exec` does fire
hooks, and the payload is Claude's apart from the spelling — `session_id`, `turn_id`,
`transcript_path`, `cwd`, `hook_event_name`, `prompt`, and `last_assistant_message` on `Stop`.

- **Routing is by environment, not by file.** `MCPDefaults.portEnvironmentKey` and
  `sessionTokenEnvironmentKey` are exported by `routed(_:for:)` and read by the hook command,
  which is what lets one shared file attribute every session correctly. Verified that a hook
  inherits the launch environment.
- **Which is also what keeps the file *stable*.** Codex pins a trusted hook by hashing its text,
  so a URL carrying today's port would revoke the user's trust on every app launch.
  `CodexHookInstaller` therefore rewrites only on a real change, and a second install returns
  false.
- **`CodexHookInstaller` merges rather than replaces**, marks its own entries with
  `MCPDefaults.hookMarker`, and removes only those on uninstall. This machine's own
  `~/.codex/hooks.json` was written by another tool, which is why that is a rule and not a
  nicety.
- **The command guards on the token** (`[ -n "$SKALMAN_SESSION_TOKEN" ]`), because the file is
  read by every Codex run under that account, including the ones the user starts themselves.

Both halves are opt-in and separate (`AppSettings.installsCodexHooks`,
`bypassesCodexHookTrust`), because only the second has a security cost: installing writes to a
file the user owns, while `--dangerously-bypass-hook-trust` un-gates *every* hook in that folder
rather than only ours — and an agent can write to `hooks.json`. The safe path is one manual
approval in the Codex TUI, which the stable-text rule is what makes viable.

`SessionStart` also **replaces `CodexSessionDiscovery`'s job**: it hands over `session_id`
already attributed by the token in the URL, where discovery watches the rollout directory and
matches on a launch timestamp. `AgentRuntime.adoptReportedIdentifier` only updates a session
still `awaitingIdentifier`, so Claude's own report — of an id Skalman minted — is a no-op.

**Codex brokers permissions on the same hook, and honours the answer.** Measured on 0.144.6: a
`PreToolUse` reply of `permissionDecision: deny` stops the tool outright — the run logs
`PreToolUse Blocked`, the file was not written, and the reason reaches the model, which then
explains itself in its own words. Its payload names the tool with the same `tool_name` /
`tool_input` keys Claude uses, so `MCPServer.routePermission` parses both unchanged. What
differs is the *vocabulary* inside: the tool is `apply_patch` and its argument is a
`*** Begin Patch` envelope, which is the same mismatch `TranscriptReplay.normalised` and
`CodexPatch` already exist to absorb.

`ToolIdentity` knows **both vocabularies**, which is what the type is for — a behaviour,
independent of the provider spelling that introduced it. Codex's names were taken from 1008 real
rollouts rather than from a list, which is the only reason the long tail was found:
`exec` / `exec_command` / `shell_command` / `write_stdin` → `.bash`, `apply_patch` → `.edit`
(a patch has old *and* new text, so it feeds the same `DiffView`), `view_image` → `.read`,
`update_plan` → `.plan`. Everything Codex-specific — spawning agents, goals, simulators — stays
`.unknown` on purpose, because mapping a tool onto an identity also hands it that identity's
permissions.

**This fixes rendering, not prompting, and the difference is worth stating.** Measured across
those rollouts: 59,335 of 64,785 calls (92%) previously drew as unrecognised tools and now carry
the right glyph and diff — but only 204 (0.3%) become auto-allowed. 82% of all Codex tool calls
are shell execution, which legitimately prompts.

That asymmetry is Codex's, not ours: Claude has distinct `Read` / `Grep` / `Glob` tools that the
allowlist can admit, while Codex reads files by shelling out. So the *command* has to be read,
which is what `ShellCommandPolicy` does — the same thing Codex's own `untrusted` approval policy
does, and the only way one tool name covering both reading and writing can be judged at all.

**It is built to be wrong in one direction only.** A missed approval costs a click; a wrong one
runs something destructive unasked. So the allowlist is short and explicit, and anything that
could reach a command the policy never sees is refused outright: redirection, substitution,
backgrounding, a leading variable assignment, an absolute path in place of a bare name. Splitting
on operators is deliberately naive, and that is safe *because* it is naive — a `;` inside a
quoted argument splits into a segment whose first word is not allowlisted, so the line is refused
rather than admitted.

Three rules came from measuring 5,165 real Codex commands rather than from reasoning, and each
was wrong first:

- **`sed` had to be admitted, narrowly.** `sed -n '1,220p' file` is how Codex *reads* — 42% of
  its shell calls — and refusing it left the classifier admitting 20% of real traffic. It is
  also the one allowlisted command that can write (`-i`, `-f`, a `w` in the script), so the
  *script itself* must be a bare line range ending in `p`. Of 2,650 real calls, none used `-i`
  or `-f`.
- **`&&` is a chain, not a hazard.** Banning the character outright made a chain of reads
  prompt, which is most of them; every link is vetted independently instead, and a *lone* `&`
  is still refused because it detaches what came before it.
- **`sed -n '10,$p'` prompts anyway**, and is left prompting: the `$` ban runs first and cannot
  tell `$p` inside single quotes from a variable without tracking shell quoting. Refusing a rare
  legitimate form is the price of not having to be right about quoting.

Together those take real-world coverage from 20% to **59%**, measured by
`ShellCommandPolicyCorpusTests` running the policy over this machine's own rollouts — the unit
tests pin the rules, that one pins the thing the rules exist for, and it fails if a change
quietly undoes the measurement. A second corpus test asserts nothing destructive is ever
admitted.

The `PreToolUse` entry is written **unconditionally** and guarded on
`MCPDefaults.brokerEnvironmentKey`, which only `streamPlan` exports. Installing it per-surface
was the obvious alternative and is wrong: `hooks.json` would be rewritten every time a session
changed surface, and every rewrite costs the user's trust decision. An entry that is inert
until an environment variable appears is how one shared file serves two surfaces.

**A hook is invisible by construction**, which is the same problem `ProjectIconResearch` has and
is answered the same way: every run leaves a record. `EventLog.Category.hooks` is the durable
half, and it is deliberately *not* fed per turn — the boundaries themselves go to
`SkalmanLogger` at `.debug`, which is the live `log stream` view, while the journal keeps only
what a report weeks later would need:

- **The one transition that matters** — a session going from inferring its state to being told
  (`AgentRuntime.applyLifecycle`). "Did the hooks reach this session at all" is the first
  question any bug report raises, and this is the only line that answers it.
- **Every rejected report** — an unknown token, an unnamed event, an empty body. A report that
  arrived and was refused looks exactly like a hook that never ran, and the causes are
  unrelated.
- **A rewritten `hooks.json`**, because a rewrite is the moment the user's Codex trust decision
  stopped applying. It is the answer to "these worked yesterday".
- **A launch with no listener port**, which silently disables the whole feature.

`HookOutcomeLog` covers the one failure the app cannot otherwise see: a hook that never
*reaches* the listener leaves nothing here, because nothing arrived — while the agent sits on a
blocked tool. `--include-hook-events` is passed for that and only that, and Claude's
`hook_response` carries the `outcome`, `exit_code` and `stderr` this side never observed
(verified against a hook made to exit 7). It is read outside `StreamEvent`, which is a pure
function feeding the conversation's rendering: a diagnostic nothing draws does not belong in the
model the views are built from. The parsing is split from the logging so the decisions are
testable, and a *missing* `outcome` counts as a failure — the schema belongs to the CLI, and a
renamed field should make the journal noisy rather than quietly stop reporting.

One bug worth keeping: every command reads stdin **before** its guard
(`skalman_payload=$(cat)`). A guard that returns without reading leaves Codex writing the event
into a pipe nobody drains, and it is the *unrouted* runs — the user's own terminal sessions —
that would pay for it. Found by a probe whose hook posted an empty body, and pinned by a test.

### The Store

Projects and sessions live in **SQLite** (`skalman.db`), not in `projects.json`. The system
`libsqlite3` — macOS ships 3.51 with FTS5 — so `import SQLite3` keeps the one-dependency rule
intact, and there is no ORM: a dozen queries are fewer lines than a query builder.

**Thin rows, JSON payloads**, which is opencode's own shape (they made this same move, from
per-file JSON to `opencode.db`, and their schema keeps `message.data` and `event.data` as
`TEXT`). Columns exist to be ordered by, filtered on or joined — `position`, `kind`,
`last_active_at`, the foreign key — and everything else rides in `data` as the model's own
`Codable` encoding. A field added to `AgentSession` therefore costs no migration, which is what
makes the schema survivable in a model still growing side chats, archiving and typed ids. A
project's payload is stored with `sessions` **emptied**, because sessions are rows; giving the
same fact two homes is how one of them goes stale.

Writes are **per row, in one transaction**: upsert what is there, delete what has gone. That is
the actual gain over the document — the store is no longer rewritten in full every time an agent
renames a terminal tab — and it retires the rolling `projects.json.bak`, whose whole job was
covering the window in which a full rewrite could be interrupted. WAL is the other half: a read
never blocks the writer, and `busy_timeout` turns "another process has it" into a wait. That
makes multiple writers *possible*, not permitted — `SingleInstanceLock` still stands, and is a
chosen concurrency model rather than a workaround.

**The import runs once and keeps its rollback.** A `projects.json` is read through the decoder
and migration chain it always used, written into the database in a single transaction, and then
*renamed* to `projects.json.migrated` — never deleted. opencode's own migration is the reason:
an update that recreated its storage directory without migrating took users' legacy sessions
with it. The same applies to the panel layouts, which were `panels/<uuid>.json` and are now
rows; their cached PNGs stay files, because a PNG in a database is a PNG with extra steps.

Quarantine still works exactly as it did for the document, because `ProjectStore` never learned
the difference: an unopenable database is moved aside (with its `-wal` and `-shm` sidecars
deleted, or SQLite would recover a fresh database from them) and reported, which is what lets
the store refuse to write over state it could not read.

`ProjectDatabaseTests` imports **the machine's own `projects.json`** into a throwaway database
and compares ids, order, titles, accounts and resume identifiers. A fixture proves the code
path; that one proves the file the user will actually migrate, which is the only copy they
cannot get back.

### Diagnostics and Drafts

Both exist because of one crash (22 July 2026), and each answers a different half of it.

`SkalmanLogger` is `os.Logger` and is the *live* view — `log stream` while a bug reproduces.
It is useless afterwards: `os_log` keeps `.debug` and `.info` in a memory ring buffer, and
only `.error`/`.fault` reach disk. Measured after that crash, `log show --predicate
'subsystem == "com.skalman"'` returned **not one line** for the minute the app died in.

`EventLog` is the durable half: JSONL under `Logs/skalman-<date>.jsonl` in Application
Support, a file per day, pruned at two weeks, surfaced by Help ▸ Reveal Diagnostics Log.
Appends are **synchronous and unbuffered**, because the record that matters most is always
the one written immediately before the process died — which is exactly what an async
hand-off loses. Lifecycle only: app launch/quit, a composer submit, each agent's command
line before it runs, each exit code.

The two stay separate rather than becoming one wrapper. `Logger`'s privacy annotations
(`\(id, privacy: .public)`) live inside the `OSLogMessage` literal and cannot be rendered
back out as a string, so a type feeding both would have to drop them at every call site.

A launch writes a marker that only `endLaunch` removes, so the *next* launch is what reports
`Previous launch did not quit cleanly` — consumed on read, so one death is one record rather
than a standing complaint, and it carries the path of the matching `.ips` from
`~/Library/Logs/DiagnosticReports/`.

`DraftStore` keeps composer text per project. That text is the one thing in the app that
exists nowhere else while it is being written: no transcript (the agent has not launched), no
scrollback (there is no terminal), no shell history (the login shell `exec`s the agent). It
is written **on the keystroke, not on a timer** — the opposite of `ProjectStore`'s coalesced
saves, and for the opposite reason: the file exists *for* the crash that lands between two
keystrokes, so a coalescing window is the one interval it cannot afford.

Submitting records the prompt to the journal *before* clearing the draft. Clearing first
would reopen the original hole — the prompt would live only in memory and in a command line,
which is precisely where it was when the crash took one.

The crash itself was in the SwiftTerm fork: `LocalProcess.processTerminated()` reaps the
child with `waitpid`, which destroys the kernel event its `DispatchSourceProcess` is
registered for. Left active, that knote is reported `EV_VANISHED` the next time the workloop
re-arms — which happens when an *unrelated* session starts a PTY — and libdispatch treats an
unexpected `EV_VANISHED` as a fatal client bug. The source is cancelled where the child is
reaped, and deliberately not in `terminate()`: cancelling before the exit event arrives would
leave a zombie instead.

### Side Chats

A **side chat** is a session forked from another: it opens carrying the parent's context and
keeps its own record, so a question can be asked without joining the conversation it asks
about. `⋯` on a session row offers **New Side Chat** and **Ask on the Side…**, the second
being the same fork with its question already asked, delivered through the composer's own
`pendingPrompt`.

The primitive is `--fork-session`, and every claim here was measured on Claude 2.1.217 rather
than inferred:

- It **copies the context into a new transcript** and leaves the parent's file untouched —
  which is what lets a side chat run *beside* a live session instead of queueing behind it.
  That is the difference from the surface switch, whose whole constraint is one live process
  per identifier.
- It **honours `--session-id` alongside it**, so the child's identifier is minted up front
  like any other Claude session and never has to be discovered.
- It records **no lineage**. The fork's copied records have their `sessionId` rewritten to the
  child's; the only trace of the ancestor was a stale snake-case `session_id` left on a single
  record. So `AgentSession.forkedFrom` is Skalman's own bookkeeping, not something read back.

Claude only (`AgentKind.supportsForking`): `codex exec resume` takes an id and a prompt and
offers nothing else. Forging a Codex fork by copying its rollout is plausible — `SessionMigration`
already proves transcripts are portable client-side files — and unproven, so it is not offered.

`AgentLauncher.forkParent(for:in:)` decides, and reads the **project's own** sessions rather
than `ProjectStore.shared`: a fork resumes its parent's transcript, which is found through the
project's folder and the parent's account, so `ProjectStore.addSideChat` puts the child in the
parent's project and inherits both. The gate closes once `hasLaunched` — the fork is a birth,
not a mode, and from the second launch the child owns a transcript and resumes like anything
else. Without the parent's transcript on disk it falls through to an ordinary fresh launch,
the same rule the plain resume applies to itself.

In the sidebar a side chat nests under its parent (`SessionNode.childNodes`), and a session
row is expandable only once something was forked from it — the earns-its-level rule, one
level below branch grouping. The row takes a **fork glyph in place of the agent's mark**,
which it can afford: a fork necessarily runs its parent's agent and account, and its parent is
the row directly above, so the agent is the one thing there that cannot differ. The hover
popover spells the lineage out. Two records are tolerated rather than trusted, because
`projects.json` outlives any release: a **missing parent** leaves the row at the project level,
and a **cycle** is refused outright, since the outline view asks for children lazily and would
recurse forever.

What fork does *not* give is a merge back. Transcripts do not merge; the honest operation is
pasting a conclusion into the parent as a message, which is not built. And the first turn
replays the whole copied context, so forking a large conversation costs real tokens.

### The Shell

A shell is **not a kind of session**. It was one for most of this project's life — a sidebar row
beside the chats, with a title, a launch record, a branch field and an account slot it could
never use — for something with no conversation to resume, no transcript, nothing to import and
no scrollback that was ever persisted. Every one of those fields was a hole, and the code around
them was a run of branches saying *not for shells*: in the launcher, the replayer, the account
discovery, the usage service, the brand icons, the migration.

It is now a **drawer under the conversation** (`ShellDrawerViewController`, ⌃`), which is what
it always was in practice: a place to run a command *about* the conversation you are reading.
`AgentKind` is down to `.claude` and `.codex`, and `supportsResume`, `supportsAccounts` and
`supportsNativeUI` collapsed to `true` — that is the measure of how much of the model existed to
describe the absence.

Three decisions worth keeping:

- **It opens where the agent is**, not where the session started. A terminal session reports its
  directory over OSC 7, so `TerminalSession.effectiveWorkingDirectory` is asked at the moment the
  shell starts — an agent that has spent ten minutes inside a subpackage hands its shell that
  subpackage. The project folder is the fallback, which is also exactly right for a natively
  rendered conversation: no PTY to ask, and the CLI was launched there anyway.
- **It takes the session's resolved profile** (`ThemeAssignments.profile(for:)`) — the same call
  the agent's own terminal makes — so a themed session's drawer matches the surface above it.
- **The process is the feature.** One shell per session, started on first reveal (a drawer never
  opened costs nothing), kept alive across session switches, and terminated with the session. A
  shell that forgot its directory and history on every switch would be worse than the terminal
  beside it.

The pane is not a split view: the conversation fills it and the drawer is a strip taken off the
bottom, always installed and zero-high when closed, so every session surface pins its bottom to
the drawer's top and opening one is a change of constant. A split view would have brought its own
collapse behaviour, delegate and priorities, all of which would need arguing out of the way.

**Existing shell sessions were dropped, not converted** — there was nothing to convert. The
version-1 → 2 state migration strips them before decoding, which it must: a kind the model no
longer has does not decode, and one undecodable session would otherwise fail the whole document.

### Session Names

A session carries three names, resolved by `displayTitle`:

1. `customTitle` — an explicit rename, which wins and stops following the terminal
2. `terminalTitle` — the live title the agent reports, retained after it exits
3. `title` — the name assigned at creation

`launchName` deliberately excludes `terminalTitle`, so the agent's own output is never fed
back into the next launch's `--name`.

Terminal titles are stripped of their leading decorative glyph on the way in
(`ProjectStore.strippingDecoration`). Claude Code reports titles like `✻ testings`; that marker
identifies the agent in a plain terminal tab, but the sidebar already draws a status dot and an
agent icon, so keeping it would put a third symbol before every name. A title consisting only of
symbols is left intact rather than reduced to nothing.

### Themes

A terminal theme is chosen at one of three scopes — session, project, or the app default —
and `ThemeResolution.resolve` picks the narrowest one that names a theme that exists.

Two rules carry the whole design, and both are pure functions of four arguments precisely so
they could be tested without standing up three singletons and a window:

- **Absent means inherit, not copy.** A session with no `themeName` follows its project, and a
  project with none follows the default, so changing the default still moves everything that
  never opted out. Recording the current theme at creation would have frozen every session
  against the one setting most likely to change.
- **A dangling name is not an error.** Themes are identified by name, so deleting one leaves
  references behind; an unknown name degrades to inheriting from the next scope out, which is
  indistinguishable from never having chosen. A *rename* is the case that must not degrade, so
  `ThemeAssignments.rename` re-points every reference through `ProjectStore.renameTheme` — it
  is the only rename path, and `ThemeManager.renameTheme` alone would silently reset every
  session using the theme.

**The broadcast had to invert.** `TerminalSession` used to observe `.profileDidChange` and
*adopt* whatever profile it carried, which was right while there was one theme for the app and
is exactly what a per-session override must not be overwritten by. Its observer is gone;
`AgentSessionViewController` re-resolves and pushes through `updateProfile`, and
`TerminalContainerViewController` resolves the pane's backdrop from the session id rather than
reading it off the terminal view — two observers of one notification have no defined order, so
reading the view could paint the pane the colour it is leaving.

Only the *theme* is scoped. The rest of a profile — font, cursor, shell, scrollback —
describes how the user works rather than how one conversation looks, and `ThemeAssignments.profile`
returns the global profile carrying a resolved theme.

The assignments live on the records they theme (`AgentSession.themeName`, `Project.themeName`
in `projects.json`) rather than in a side table, so each is deleted with the thing it applies
to instead of outliving it and re-theming whatever reuses the identifier.

`ThemeColorKey` names the palette's twenty colours once, as key paths with a `displayName` and
a snake-case `wireName`. The settings editor previously kept a `[String: NSColorWell]` and a
twenty-case `switch` to put a changed colour back, and the MCP schema needs the same mapping —
generating the tool's schema from the enum is what stops a colour being added to the model and
left out of the schema an agent reads.

**Scope is chosen where it applies**, which is a session's or a project's own `⋯` menu — the
same placement as the surface switch and the project icon. Only the default lives in Settings,
being the scope with no row to hang from. Each menu's "Inherit" item names what it inherits,
since that is the one choice in the list whose result cannot otherwise be seen, and every item
carries a `ThemeMenuChoice` naming its own target rather than reading "whichever row was last
clicked" — the submenu is built from three places and that ambient state goes stale between
them.

Agents reach the same three scopes over MCP (`list_themes`, `set_theme`, `create_theme`). The
call already arrives attributed, so `set_theme` needs no argument saying which terminal and
defaults to the session that asked — which is what makes "make this one darker" work in the
conversation it was said in. Three things the tools do that a thinner wrapper would not:

- **`set_theme` reports what the session actually draws with afterwards**, which is not always
  what was just set: a project-wide change is invisible in a session that named its own theme,
  and saying so is the difference between a tool that worked and one the agent believes worked.
- **`create_theme` merges onto a base** — the session's current theme unless told otherwise —
  so "warmer background" is one colour rather than twenty, and it refuses to overwrite an
  existing name, because a clobbered custom theme is unrecoverable and the caller most likely
  to collide is an agent inventing one.
- **A palette whose text fails `ThemeContrast` is refused.** A theme is the one setting that
  can make the app's *input* surface unusable, and the terminal is where the user would have to
  type to undo it. Only text-against-ground is checked: an ANSI colour close to the background
  is ordinary — a dark `black` on a dark ground is how most themes are built — and the floor is
  WCAG's large-text 3:1 rather than 4.5, which would reject Solarized Dark and stop being a
  safety net and start being a taste.

A natively-rendered session records an assignment but shows almost none of it: the conversation
is drawn in system colours per the design system, so the theme reaches only the pane's backdrop.
The tools say so rather than reporting a success nothing visible followed.

The settings page was rebuilt around `ThemeColorEditor` and `ThemePreviewView`, and both
changes came from looking at a render rather than from reasoning about a control:

- **The palette is a grid.** Sixteen chips four points apart in two rows that did not line up
  read as one undifferentiated field of circles — `bright blue` could not be found in it. At
  `Design.Spacing.medium`, index-aligned so a colour sits above its bright variant, they are a
  grid with columns. There are deliberately no column headings: a red chip says "red" better
  than the word does, and eight headings wide enough for "Magenta" would set the grid's pitch
  for it. The name and hex live in each chip's tooltip.
- **A swatch is ringed, and the ring is a layer border** — which Core Animation paints *above*
  sublayers, so it survives the colour well filling the chip underneath. A theme's `black` on
  the settings card's own dark ground is otherwise a hole rather than a value.
- **A built-in theme shows its colours rather than disabling them.** Disabled wells dim, which
  misreports the palette they exist to display; the read-only state says why and offers
  Duplicate instead.

`ThemeSettingsRenderTests` draws the page at the width the pane actually gives it
(`Design.Size.readableWidth`, which `showSettingsPage` caps it at) and at a squeezed one, light
and dark — the same fixture-to-PNG idea as the conversation and git-review renders, for the
same reason: no assertion anyone would write catches "these twenty chips read as a smear".

### Icons

Two kinds of icon, resolved differently on purpose.

**Agent marks** (`AgentBrandIcons`): a session row's icon slot shows the agent's own
favicon — Claude's coral starburst, OpenAI's knot — instead of an SF Symbol. Loose PNGs under
`Resources/Icons`, loaded via `Bundle.main` (the folder is an explicit-folder resource, so it
lands under `Contents/Resources/Icons/`), *not* the asset catalogue. The OpenAI knot is monochrome by design, so it
ships as a **template image** and tints with its context like the symbols beside it — which
is what makes it work in dark mode and dim for dormancy. Claude's mark keeps its brand
colour; tinting cannot dim a non-template image, so dormancy dims it through the view's
alpha instead (`SessionRowView.applyAgentIcon`).

**Account chips** (`AccountBadge`): the mark keeps the slot and an *alternate* account rides
its bottom-trailing corner as a 9pt chip — the account's emoji, else its discovered avatar,
else an initial on a hashed disc. The two facts a row carries, which agent and which account,
had been competing for one 16pt slot and the account was winning: an alternate account
replaced the mark with a flat `c.circle.fill`, so a sidebar of alternate accounts showed no
agent at all. The chip is laid out as an **overlay** rather than a second arranged view, so
rows with and without one still align, and it hangs `cornerOverhang` past the slot because
flush inside it covered the middle of a 13pt mark.

The initial comes from the **login email**, not the alias: aliases are named after the agent
and collide on it (`claude-dblock` and `claude-vlundborg` are both `c`), while the addresses
give `D` and `L`. Its disc hashes the whole address through `GeneratedProjectIcon.stableHash`,
so two accounts sharing an initial still differ by colour, on a brighter ramp than the project
tiles — a 9pt disc has far less area to carry a hue than a 16pt tile. The **default account
gets no chip**: its agent's mark already says everything the row knows.

`AccountAvatarStore.cachedEmail` memoizes the address, hit or miss. The badge asks on every
row configure and rows reconfigure constantly while an agent works, where the uncached answer
is a file read and a JWT decode for a value that cannot change while the app runs.

**Project icons** (`ProjectIcon` on `Project`; files owned by `ProjectIconStore`): the
project row shows the project's own mark, else a folder symbol. Every stored icon is
normalised through ImageIO — largest frame (`.ico` carries several), capped at 64px,
re-encoded PNG — so the sidebar never holds a 1024px app icon per row, and an HTML error
page served with a 200 fails the same decode gate that admits real images.

`ProjectIconDiscovery` fills empty slots free of any agent, and **probes known paths rather
than walking the tree**: a recursive scan would surface `node_modules/<lib>/favicon.ico` as
the project's mark. Only the `AppIcon.appiconset` search enumerates, bounded and skipping
dependency directories. Then the GitHub owner avatar (read from the *shared* git config via
`GitInfo.remoteOriginURL` — remotes belong to the repository, not a checkout), then the
favicon of the `package.json` homepage; the network sources only contact hosts the project
itself points at, plus one GitHub API call gating the avatar. Automatic discovery only ever
fills an **empty** slot; a user's explicit choice (`.custom`) is never displaced.

The avatar is admitted **only for organisation owners** (`isOrganization`, via
`api.github.com/users/<owner>`): a person's avatar puts the same face on every repo they
own, which distinguishes nothing — and any doubt (API error, rate limit) refuses rather
than guesses, because the failure mode of guessing is a face on every project. A project
with no discovered mark renders `GeneratedProjectIcon` at *draw time* — its initial on a
colour from a stable djb2 hash of the name (`hashValue` is process-salted and would
recolour the sidebar per launch) — never persisted, so the slot stays genuinely empty for
later discovery.

`SingleInstanceLock` (`flock`, held for the process lifetime) refuses a second instance at
launch, before anything touches the stores: two live instances share `projects.json`
last-writer-wins, and even *instantiating* `ProjectStore` writes it once — a relaunch
handoff between overlapping instances is how three projects lost their icon records. The
losing instance's quit path skips store teardown for the same reason.

The sidebar draws the *composed* rendition (`ProjectIconStore.displayImage`): rounded-rect
clipped, and set on a small **backplate** of the opposing tone when the icon's own
alpha-weighted mean luminance would vanish against the current appearance — a dark mark on
the dark sidebar gets a light plate, measured from the icon's pixels rather than guessed
from its source. The plate colours are fixed neutrals *on purpose*, an exception to the
system-colours rule: a plate exists to oppose the appearance, and every system colour
follows it. Rows retain the `ProjectIcon` and re-compose on
`viewDidChangeEffectiveAppearance`, since the decision is per-appearance.

`ProjectIconResearch` asks Codex to identify the mark — headless `codex exec`, read-only
sandbox, low reasoning effort, default account. Codex-only for the *sandbox*, not for policy:
the run reads an unfamiliar project's files and `--sandbox read-only` bounds it in one flag,
where Claude's headless mode — permitted, see `supportsNativeUI` — would need its tool surface
constrained explicitly for no gain here.
It is **manual-only** because it spends the user's own usage: each run is one explicit
"Research Icon with Codex" menu click, never a background default. A file path in its
answer is admitted only from inside the project's own folder — the run is sandboxed, but
our read of its answer is not.

**A headless child is invisible by construction, so every run leaves a record**: the
child's stdout and stderr — merged into one pipe, so a single reader can never deadlock
and the record holds the whole story — land in `IconResearch/<projectID>.jsonl` under
Application Support, written *before* the verdict so failed runs are exactly the ones
whose record survives. Stages log through `SkalmanLogger.agent`, and the sidebar exposes
the record as "Open Last Research Log". This observability exists because the first real
run failed silently and nothing could say where.

Agents can set the icon from inside a session via the `set_project_icon` MCP tool, its own
group on the Tools page.

**Account avatars** (`AccountAvatarStore`): a chip resolves emoji → discovered avatar →
hashed initial. The avatar comes from the account's login
email — Claude's `.claude.json` `oauthAccount.emailAddress`, the `email` claim of Codex's
`id_token` (decoded locally; the token itself is never used) — probed against Gravatar
(SHA-256, `d=404` so a miss is a status code) and then GitHub's public-email user search.
The person-avatar ban on project rows *inverts* here on purpose: an account is a person,
and different logins carry different faces, so the avatar distinguishes. Hits land in
`AccountAvatars/` and refresh the sidebar through the same notification an emoji edit posts;
behind `AppSettings.discoversAccountAvatars`, which is the only thing that lets an email hash
leave the machine.

Coverage is honestly thin — of five logins on this machine only one resolved, so the hashed
initial is the chip's working case rather than its fallback. The chip's cache key carries
`hasAvatar`, so one landing later replaces a drawn initial instead of being ignored.

### Accounts

Both CLIs support multiple logins via `CLAUDE_CONFIG_DIR` / `CODEX_HOME`. Accounts are
discovered from the filesystem, not from aliases, so they are found regardless of shell setup;
aliases are read only to supply a friendly label.

Admission requires proof of a real login (`.claude.json`/`settings.json` for Claude,
`auth.json` for Codex). Two things are deliberately excluded: Claude Science data roots
(`~/.claude-science`, or any root carrying `install-id` + `runtime/` + `orgs/`), which hold
Claude-shaped state but are not login slots; and aliases that set no config directory.

**Where a login is *chosen*, it is named after the person** (`AccountName`), not after the
alias. An alias is named after the agent — `claude-dblock`, `claude-vlundborg` — so a menu of
them asks the user to tell two logins apart by four characters in the middle of a word, and
`AccountBadge`'s initial has the same collision (both are `c`). The name is derived from the
login address instead: `daniel.block3@example.com` → `Daniel Block`, dropping trailing digits
because they are almost always "that address was taken". Names are resolved for the whole
*list* at once, since the failure being avoided is only visible across it — two logins
belonging to one person derive the same name, and a menu offering it twice is worse than one
offering two aliases, so a collision falls back to the address. The alias still names sessions
and still appears in the accounts settings page, which is where it is edited.

`AccountEmailProbe` exists because the **default** Claude login is the one account that cannot
be named from disk: alternates record `oauthAccount.emailAddress` in their own `.claude.json`,
while `~/.claude/.claude.json` carries a hashed `userID` and nothing else — its identity is in
the Keychain, which this app never reads. `claude auth status --json` reports `email`, honours
`CLAUDE_CONFIG_DIR`, and needs no token of ours, so the one unanswerable account is asked
directly. It costs a subprocess, so the answer is cached in `UserDefaults` and the probe runs
at most once per account per install — an address does not change while a login does not. Only
Claude: Codex's `id_token` already carries its `email` claim.

Two invariants matter:

- **The account sticks to the session.** Conversations are stored per account, so a resume
  must route to the same account or the id will not be found.
- **The default account launches with `env -u`**, not a bare command. A login shell may export
  an override, which would otherwise silently route to the wrong account.

In the sidebar an alternate account is identified entirely by the session's icon slot — its
chosen emoji, else a letter badge (`c.circle.fill`) from its name — with the full name in the
tooltip. Rows carry no account text line, which keeps every session a single-line row.

This mirrors the logic in `~/repo/claudex` (`CredentialStore`, `HandoffLauncher`).

**Moving a conversation between accounts** (`SessionMigration`) exploits that a transcript is a
client-side file the CLI replays each turn, not server state bound to the originating account.
*Verified empirically*: a Claude transcript copied into another account's config dir resumed
with full context under that account. So a move is: copy the transcript into the target
account's directory and re-point `accountHandle`. The destination is the source path with its
**account-directory prefix swapped** — the layout under a config dir (`projects/<slug>/` for
Claude, dated `sessions/` for Codex) is identical between accounts, so one prefix swap serves
both agents. It is **non-destructive** (the original stays, so a move reverses), stops any live
process first (it belongs to the old account and is still writing the file), and Skalman never
touches a token — the official CLI authenticates under whichever account, so this is
portability, not credential reuse.

Same agent only. Cross-agent (Claude ↔ Codex) is *not* a resume — the transcript formats and
resume paths differ — so it is deliberately not offered here; the honest cross-agent operation
is a re-seed (replay the normalized `[StreamEvent]` into a new session on the other agent),
which is a separate, lossy feature.

### Account Usage

The toolbar's trailing pill (`AccountUsageItemView`) shows the selected session's account
rate-limit pressure: a ring gauging the peak window beside every window's own value
(`5h 43% · 7d 73%` — Claude's own status-line vocabulary), monochrome until 75%, orange then
red past 92%, each value tinted by its own window's severity; clicking opens per-window bars
with reset countdowns. `AccountUsageService` caches
per account and keeps the last good reading through failed refreshes. The credential posture
mirrors `~/repo/claudex`: read the short-lived tokens the official CLIs already keep, never
refresh them, and **never read the Keychain** — its `Claude Code-credentials` items do not
say which config directory they belong to, and an unbundled binary re-prompts every rebuild.

Sources, per provider:

- **Codex** — `auth.json` (`tokens.access_token` + `tokens.account_id`) against
  `chatgpt.com/backend-api/wham/usage`, with the `ChatGPT-Account-ID` and `originator`
  headers the backend gates on. Primary/secondary windows are *positions*, not timeframes —
  each is named from its own `limit_window_seconds`.
- **Claude** — `<config>/.credentials.json` against `api.anthropic.com/api/oauth/usage`
  when the file exists. On this machine it does not (macOS keeps the token in the Keychain),
  so the working source is **Claudex's status-line cache**:
  `~/Library/Application Support/Claudex/ClaudeStatus/<profileID>.json`, where `profileID`
  is the lowercase-hex SHA-256 of the standardized, symlink-resolved config-dir path
  (Claudex's own recipe, verified against the real cache files). Claude Code pushes
  `rate_limits` into that feed on every turn, so it is fresher than any polling — and reads
  as `source: .localCache`, which shortens the re-read interval from 300s to 30s.

A window whose `resets_at` has passed keeps its identity but not its percentage — the stale
value describes the *previous* window, so it renders as `—`, never as pressure. The pill
hides entirely for accounts with no usage source (Claude without either
source): a control with nothing to say is noise in the always-visible corner.

The same reading is put where an account is **chosen**, because that is the moment the number
changes a decision; the pill speaks only after the session exists. Twice over, at two
resolutions:

- `AccountUsageMenu` writes each login's `compactSummary` onto its item in the account chip's
  menu, so the accounts are compared *before* one is picked. It shows the *cached* value and
  starts a refresh — a menu is built synchronously and a fetch is a network round trip, so
  the alternative to what is known is nothing at all. `prefetch()` is therefore called where
  the surface *appears* (launch, and each time the composer is shown) rather than where the
  menu opens, which is already too late for that open.

  It also carries a **ring** (`UsageRingImage`), because the text alone did not scale to the
  decision it exists for: `5h 0% · 7d 90%` is four numbers and two window names per account,
  so comparing three logins means reading twelve of them and holding the comparison in your
  head. A ring compares without arithmetic — the fullest one is the busiest account — and its
  tint says whether that matters. It shows the **peak** window rather than the first, since an
  account at `5h 0% · 7d 90%` is nearly out and a ring drawn from the 5-hour window would say
  the opposite. Drawn rather than composed from views, because `NSMenuItem` takes an image and
  no view at all — the same constraint that produced `ThemeSwatchImage`. The numbers stay: the
  ring is the glance, the text is the precise answer.
- `AccountUsagePanelView` draws the chosen account in full under the chips: a `UsageWindowRow`
  per window, each with the **time mark** that makes the number legible — fill short of the
  mark is under pace, past it is spending faster than the window refills.

`UsageWindowRow` and `UsageBarView` are shared with the toolbar's popover rather than
reimplemented: the composer and the popover ask the same question, so they draw the same
answer. The panel takes a *reading*, not an account — the composer owns the fetch and the
notification, the view owns the drawing, which is also what lets it be rendered from
synthetic data in a harness.

`AccountUsage.compactSummary` is plain text for menus and tooltips; the pill keeps its own
attributed build, which the model cannot produce because each value carries its own window's
severity colour.

```
Select session → AgentLauncher.plan() → login shell → cd <project> && exec <agent>
                                                              ↓
                          agent exits → PTY torn down → session marked dormant
                                                              ↓
                  row stays in sidebar → select again → resume by agent session id
```

Launches go through a **login shell** because a GUI app does not inherit the user's
interactive `PATH`, and the agent CLIs live in `~/.local/bin` or a Node prefix.

Claude accepts `--session-id <uuid>`, so the id is minted up front. Codex has no equivalent,
so its id is read back from the `session_meta` record at the head of the rollout file it
writes under `~/.codex/sessions/`.

### Session Import

`SessionImporter` discovers conversations started outside Skalman by reading the transcripts
the CLIs already keep, so a session can be adopted into a project and resumed by id.

Reading these files has two traps, both of which cost real coverage before they were fixed:

- **Never cap a record read at a fixed byte count.** A Codex `session_meta` line carries the
  project's instructions, so it runs to tens of kilobytes and grows with `AGENTS.md` — a 16 KB
  cap silently skipped 62% of rollouts, because a truncated line is not parseable JSON. Read
  until the record ends, and bound the *scan*, not the record.
- **The opening turn is not near the top.** Codex writes telemetry (`token_count`,
  `agent_reasoning`) ahead of the conversation, and compaction pushes the first user turn
  further still — past 500 KB in ordinary sessions. `forEachRecord` therefore streams and lets
  the caller stop, so the usual file costs one chunk while a buried turn is still found.

Titles come from the record that holds only what the user typed: Claude's `ai-title`, and
Codex's `event_msg`/`user_message` — *not* the `user`-role messages, which replay the CLI's
own instruction blocks. A transcript with no user turn is not offered at all: Codex writes a
rollout for its approval reviewer against the same project directory, and those are machine
turns nobody can meaningfully reopen.

**A chat is attributed by which worktree it ran in, not by a raw path.** Every transcript
records the directory it launched in — Codex's `session_meta.cwd`, and Claude's per-record
`cwd` (the project-slug directory name is a *lossy* encoding, since two different paths can
slug alike, so the recorded path is the authority). `belongs(cwd:folder:worktree:)` resolves
that path to its worktree via `GitInfo.worktreeIdentity` and admits it only when it is the
project's folder, or a subdirectory *of the same checkout*. This is what keeps a worktree
nested inside the folder — the common `<repo>/.git`-adjacent layout, e.g.
`sonda/.claude-worktrees/SONDA-348` — *out* of the parent project: it is a separate checkout
with its own git directory, on its own branch. The equal-path case, which is almost every
rollout, is settled without touching disk. This mirrors how opencode anchors a session
(`rev-parse --git-dir` vs `--git-common-dir`), read off disk rather than by shelling out.

Verify against disk rather than by eye — `~/.codex/sessions/**/*.jsonl` and
`<claude config>/projects/<slug>/` are the ground truth, and both are cheap to count. The
worktree rules resist real data (no subdirectory-launched chats exist here) so they are proven
against a built layout — main + nested + sibling worktrees — rather than only observed.

### Data Flow

```
User Input → LocalProcessTerminalView → PTY → Agent Process
                       ↓
Agent Output ← LocalProcessTerminalView ← PTY
                       ↓
             (SwiftTerm handles parsing internally)
```

### Key Protocols (SwiftTerm)

- `LocalProcessTerminalViewDelegate`: Receives process lifecycle events
- `TerminalViewDelegate`: Receives terminal state changes (title, size, etc.)

## Design System

**New UI is built from `Sources/Skalman/UI/Design/`, not from stock AppKit controls.** This is
the default, not a preference: a screen assembled from `NSPopUpButton`, `NSBox` and bezelled
buttons will not match anything else in the app.

`Design.swift` holds every measurement, weight and surface colour. Reach for a token rather
than a number — a literal in a view is how the language erodes. The scale is deliberately
small (`Spacing` is 2/4/6/10/12/20/32); a value between two steps is nearly always a mistake.

Components so far:

| | |
|---|---|
| `ChipView` | A flat pill that opens a menu. The standard way to offer a choice. |
| `PromptView` | A rounded container holding a growing text view and its submit control, as one input. |
| `ThemedControl` | The base for a control that draws itself from the theme. |
| `ThemedToggle` | A drop-in `NSSwitch` whose on-track is the theme's accent. |
| `ThemedPopUp` | A drop-in `NSPopUpButton`, button included and dropdown excepted. |

`PromptView` is an `NSTextView`, not an `NSTextField`, for two things a single-line field
cannot do: a task worth describing runs past one line, and what is dropped on a composer is
as often an image as it is text. It grows with its content to `Design.Size.inputMaxHeight`
and scrolls past it; Return submits and Shift/Option-Return breaks the line, which is the
shape every chat composer has and is what lets it be multi-line without losing the one-key
send.

Height is re-measured in `layout()`, not only when the text is set. Text height depends on
the width the box was given, which is unknown at assignment — a draft restored before layout
measured against a container of the wrong width and opened at the wrong height, showing the
*tail* of the prompt. Setting text also scrolls back to the top for the same reason.

Drops and pastes both land in `readSelection(from:type:)`, so one implementation serves the
pointer and the keyboard. Files become their own paths; raw image data is written to the
temporary directory first (`PromptAttachment`) — a screenshot on the pasteboard has no path,
and a path is the only form of an image either CLI can act on. This is what the agent CLIs do
with their own pasted images.

The vocabulary these encode, which new work should follow:

- **Flat over bezelled.** Pills and panels with a subtle fill. Stock bezels are heavier than
  anything here and pull attention away from content.
- **Quiet until relevant.** Surfaces rest below full opacity and lift on hover. A control
  offering a single option *hides* rather than showing a dead menu — the composer's account
  and model chips both do this.
- **Content leads.** One element per view carries emphasis, usually what is being typed into
  or read. Everything else is secondary or tertiary label colour.
- **System colours only.** Every surface derives from a system colour, so light and dark both
  work and the accent is the user's own. No hardcoded RGB.
- **`.continuous` corners.** The default circular curve looks subtly wrong beside system
  controls at these radii; `applySurface(fill:radius:border:)` handles this.

`SessionComposerViewController` is the reference implementation, and **the only way a session
is created**. Reading down its column is the decision in order: the project, the choices
(agent, account, model, checkout), what those choices have left to spend, then the task.

Every shortcut that created a session outright is gone — the project row's `+`, the per-agent
and per-account items in the Project menu and the sidebar, `⌘N`'s old behaviour, and the
session a newly added project used to get. Each answered four decisions with defaults the
user never saw. `⌘N` and selecting a project now both land here. The composer is replaced by
the conversation the moment it is used, so it costs a click and nothing else — which is also
why it is laid out generously rather than compactly, and why its column is
`ComposerDefaults.contentWidth` (720) rather than `Design.Size.readableWidth`: that measure
paces prose, and squeezing a row of chips into it collapsed every one of them to an
unlabelled icon.

**A chip names the answer, not the setting.** The model chip said "Default model", which tells
the user the one thing they already know — that they have not chosen — while the question it
exists to answer is *which model will this session run on*. Both CLIs record that per account
(Claude in `settings.json`, Codex in `config.toml`), so `AgentModels.defaultModel` reads it and
`ModelName` turns the identifier into a name: `claude-fable-5[1m]` → `Fable 5 · 1M`. The menu's
first item names it too, so picking the CLI's own choice and leaving it alone are visibly the
same thing. An identifier the table does not know is handed back intact rather than dropped — a
wrong friendly name is worse than an unfamiliar accurate one on the string that says what the
session costs. "Default model" survives only where the account states nothing at all.

### Themed Controls

Preferences used stock AppKit deliberately — a settings window being one place where matching
the platform beats matching the app. **App themes ended that argument**, because under a style
there is no platform look left to match: a page of system-blue switches and softly-bezelled
pop-ups on a Cyberpunk-green or Swiss-red surface is not "native", it is a theme that reached
the cards and stopped at the controls. The System theme is what keeps the original promise, and
it keeps it exactly — every role resolves to the system colour, so a user who never picks a
style sees the app they always saw.

`ThemedControl` is the base and closes the whole class of bug at once. It **draws in `draw(_:)`,
never into a frozen layer** — `layer.backgroundColor = colour.cgColor` resolves once and keeps
that value, which is why a live theme switch used to leave stale colours across the app — and it
answers a theme change with one `needsDisplay = true`. Subclasses read `Design.*` roles at draw
time and inherit the redraw.

It also has to declare `isAccessibilityElement`. A stock control is one because its *cell* is,
and a control that draws itself has no cell; without it a themed control is invisible to
VoiceOver and to UI scripting alike. That was found by a settings page reporting no pop-up
buttons on a page that visibly had one.

`ThemedPopUp` is where the one genuinely unthemeable thing is contained: **the menu a pop-up
opens is drawn by the window server**, outside any view this app owns, so its chrome cannot
follow the theme. Call sites depend on the wrapper rather than on the menu, so replacing that
dropdown with a custom popover later is a change to one file. Two smaller rules earn their
keep — an item that carries its own action keeps it (which is the whole of how a pull-down like
the themes gear works, and only unclaimed items route through the control), and an
out-of-range `selectItem(at:)` leaves the control unselected rather than trapping, since the
index usually comes from looking a stored preference up in a list that may have moved on.

## Code Style Guidelines

### Constants & Configuration

All magic numbers and string literals must be defined as constants:

```swift
enum TerminalDefaults {
    static let columns = 80
    static let rows = 24
    static let scrollbackLines = 10_000
    static let defaultShell = "/bin/bash"
    static let defaultFont = "SF Mono"
    static let defaultFontSize: CGFloat = 13
}

enum WindowDefaults {
    static let minWidth: CGFloat = 400
    static let minHeight: CGFloat = 300
}
```

### Naming Conventions

- Types: `PascalCase` (e.g., `TerminalSession`, `CursorStyle`)
- Properties/Methods: `camelCase` (e.g., `currentDirectory`, `startShell()`)
- Constants: `camelCase` within enum namespaces
- File names match primary type name

### Structure Organization

```swift
// MARK: - Properties (public, then private)
// MARK: - Initialization
// MARK: - Public Methods
// MARK: - Private Methods
// MARK: - Protocol Conformance (each protocol gets its own extension)
```

### DRY Principles

- Extract repeated logic into well-named helper methods
- Use protocol extensions for shared behavior
- Centralize color/theme definitions in a single source
- No hardcoded literals - use constants

### Error Handling

```swift
enum TerminalError: LocalizedError {
    case shellNotFound(path: String)
    case sessionCreationFailed

    var errorDescription: String? { /* ... */ }
}
```

## File Organization

```
Sources/Skalman/
├── App/                    # App entry point, AppDelegate
├── Core/
│   ├── Constants/          # TerminalConstants.swift
│   ├── Agent/              # AgentLauncher, AgentRuntime, CodexSessionDiscovery, GitInfo
│   ├── MCP/                # MCPServer, MCPConnection, MCPSessionRegistry, MCPTools
│   ├── Logging/            # SkalmanLogger (os_log), EventLog (durable journal)
│   └── Session/            # TerminalSession, ProjectStore, StateManager, DraftStore
├── UI/
│   ├── Design/             # Design.swift tokens, ChipView, PromptView
│   ├── Windows/            # MainWindowController
│   ├── Views/              # Sidebar, terminal container, custom NSViews
│   └── Preferences/        # Settings UI
├── Models/                 # Project, AgentSession, TerminalProfile, TerminalTheme
├── Extensions/             # NSColor+Terminal, etc.
└── Resources/              # Assets, fonts
```

## Testing

- Unit tests for `TerminalSession` state management
- Unit tests for `TerminalProfile` serialization
- Integration tests for shell spawning
- UI tests for keyboard input handling

## Documentation

### IMPROVEMENTS.md

The prioritized reliability/type-safety roadmap from the July 2026 architectural review,
kept as a working checklist. When fixing anything it lists, check the item off there; when
touching a subsystem it covers, read its entry first — several items (persistence
quarantine, `@MainActor` adoption, typed IDs) change the rules new code should follow.

### USER_GUIDE.md

The `USER_GUIDE.md` file documents all user-facing features, keyboard shortcuts, and behaviors. **Keep it in sync** when:

- Adding new menu items or keyboard shortcuts
- Adding/removing/changing user-visible features
- Modifying preferences or settings
- Changing state persistence behavior
- Adding new UI components (find bar, process tree, AI mode, etc.)

The guide is organized by feature area with a comprehensive keyboard shortcuts reference at the end.

## Important Notes

- **No App Sandbox**: PTY operations require sandbox to be disabled
- **Hardened Runtime**: Enable with exceptions for PTY
- **SwiftTerm handles**: Escape sequence parsing, screen buffer, cursor management, Unicode
