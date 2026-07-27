# Native Conversations

Rendering a session in Skalman instead of a terminal: the transports, the permission brokering, the rendering model and the turn rail.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

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

**The status line says one thing per turn** (`WorkingWords`). While a turn is in flight the
label draws from a twenty-word vocabulary — "Pondering…", "Untangling…", "Sharpening pencils…" —
and the word is chosen at submit and held until the turn ends, because a label that rewrote
itself mid-wait would report a change that had not happened. Variety belongs *between* turns.
`WorkingWordCycle` is a shuffle bag rather than a random pick: independent draws repeat, and the
same word twice running reads as the status having stopped updating.

Choosing at submit is also what makes the two transports agree. The status used to be raised
from whatever each CLI reported, so Claude — which streams `thinkingDelta` — flipped to
"Thinking…" a moment in, while Codex, whose `exec --json` emits reasoning only as a finished
block, sat on "Working…" for the whole turn: one wait, described two ways, for a reason no user
could see. A word drawn where the turn starts asks neither CLI anything. `thinkingDelta` now
moves no status at all, and reasoning still lands as its own row when the message finishes.

Beside the word, a **dotted orb spins while the turn is in flight** (`WorkingOrbView`, the
`ThinkingOrbs` dependency). It is shown only for the `working` status and hidden otherwise;
in the status `NSStackView` a hidden arranged view detaches, so an idle "Ready" sits flush at
the leading edge rather than behind a reserved gap, and the orb's own display link idles the
moment it is hidden. It draws in the theme accent — see the Dependencies note on the `tint`
fork — so it belongs to the current app theme rather than drawing plain black-on-white.

The checkout's floating status card becomes a **run receipt** over the same interval. Plan
tools are reduced to provider-neutral `RunProgress`: Codex's `update_plan` reads `plan`, and
Claude's `TodoWrite` reads `todos`; both become `Step n / total`. `ConversationTimeline`
reports that as a change beside the ordinary tool row, and the controller exposes it to the
container without handing provider arguments to a view. No plan means `Working…`, not a
guessed fraction.

The receipt's file and line totals do not come from tool calls. A shell command, an MCP tool or
a subagent can edit without producing an Edit block, so counting structured tools would be a
plausible lie. `GitChangeMonitor` keeps watching the checkout and independently rebuilds the
same card after each coalesced FSEvents burst. Plan and git updates can therefore arrive in
either order, and either refresh preserves the other half.

Native activity now follows the **turn**, not the transport process:
`ConversationViewController.isTurnInFlight` enters on submit and leaves on the terminal turn
event. Claude keeps one process alive while idle and Codex spawns one per turn, so
`stream.isRunning` cannot answer this. Feeding the real working edge through the existing
delegate also gives Last Turn its baseline for native sessions rather than only terminal ones.

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

## Conversation Rendering

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

## The Turn Rail

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
