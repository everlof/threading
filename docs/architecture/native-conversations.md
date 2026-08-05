# Native Conversations

Rendering a session in Threading instead of a terminal: the transports, the permission brokering, the rendering model and the turn rail.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

A session can be rendered by Threading instead of shown as a terminal. `AgentSession.usesNativeUI`
picks the surface, chosen at creation and **switchable afterwards** from a dedicated pane-header
button or the **Interface** submenu. The button always names and depicts the destination
(`SessionSurfaceTogglePresentation`); the submenu offers both explicit choices and marks the
current one.

There is only one session action menu implementation:
`ProjectSidebarViewController.populateSessionActions`. A row's hover `⋯`, its right-click menu,
and the pane header's **Context** button all set `actionSessionID` and call that builder. Core
actions, checked state, runtime-only actions, attachment access, and extension commands therefore
cannot silently diverge between the chat and the header.

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

The mode is gated behind `AgentKind.supportsNativeUI`, which admits Claude, Codex, and Grok.
OpenCode remains terminal-only: its TUI/resume CLI is enough for an honest terminal integration,
but native rendering still requires a measured transport and transcript replay. Neither is
inferred from terminal output or private storage.

Structured execution also crosses a separate boundary before presentation normalization. Claude's
native tool blocks, Codex App Server item notifications and Grok ACP tool updates are handed to the
[Execution Audit](execution-audit.md) adapters before `StreamEvent` turns them into shared timeline
rows. This preserves exact native inputs/results without admitting prompt, reasoning or assistant
prose into the audit store.

**Claude was gated off here for most of this project's life, and no longer is.** The reason it
was disabled — `claude -p` runs on the user's subscription, and Anthropic's terms reserved
subscription OAuth for Claude Code and claude.ai — described the February 2026 wording
accurately and has since been overtaken. The current policy targets *routing requests through
subscription credentials on behalf of users*: offering Claude.ai login inside your product, or
lifting the OAuth token out of `~/.claude` and calling the API while impersonating Claude Code.
Threading does neither. It spawns the user's own installed `claude` binary, which authenticates
itself from whatever `claude auth login` put on disk, and Anthropic's help centre now names
`claude -p` and third-party apps built on that transport as subscription-drawing usage.

The unresolved part is economic, not legal: a June 2026 plan to move `claude -p` and Agent SDK
turns onto separate metered credits at API rates was withdrawn on the day it was to take effect,
explicitly as a pause. If it returns, native Claude sessions cost differently from terminal ones
— worth surfacing to the user then, but not a reason to keep the surface unreachable now.

```
                       ConversationStreamSession
                                  │
            ┌─────────────────┼─────────────────┐
            ▼                  ▼                  ▼
 CodexStreamSession    ClaudeStreamSession    GrokACPStreamSession
 codex app-server      claude stream-json     grok agent stdio (ACP)
            │                  │                  │
            └─────────────────┴─────────────────┘
                                  ▼
                    ConversationViewController
```

Codex native rendering uses the CLI's **app-server**, not the one-shot `codex exec --json`
surface. `CodexStreamSession` launches one `codex app-server --listen stdio://` process,
performs the `initialize` / `initialized` handshake, then calls `thread/start` or
`thread/resume`. User messages become `turn/start`; model, effort and service tier are read
from the latest `ProjectStore` record into that request, so an idle conversation can change
configuration without restarting the server or changing thread id.

`CodexAppServerEvent` maps provider-specific JSON-RPC notifications onto `[StreamEvent]`.
Agent-message deltas use the same streaming placeholder as Claude, completed messages become
markdown, command/MCP/dynamic/file/plan items become the same collapsible tool rows, and
`turn/completed` returns the composer to Ready. The older `CodexStreamEvent` adapter remains
for `exec --json` fixtures and one-shot surfaces, but it is not the native conversation
transport.

Grok native rendering uses the public **Agent Client Protocol** exposed by
`grok agent stdio`, verified against Grok 0.2.118 and ACP protocol version 1. A fresh chat sends
`session/new`; a resumable one sends `session/load`, whose standard replay notifications rebuild
the historical user, assistant, reasoning, tool, and plan rows before the composer becomes live.
The provider-returned session id is persisted just like Codex's assigned thread id. Prompts use
`session/prompt`; `usage_update` supplies the context meter; and the prompt response's stop reason
settles the turn. A standard `session_info_update` title is routed through the same protected
agent-title slot as terminal and transcript-reported names, so it cannot overwrite a user rename.

ACP is also the abstraction boundary for parity features. `available_commands_update` becomes the
ordinary provider-neutral composer catalog. Session-owning or sensitive commands such as
`/always-approve`, `/fork`, `/resume`, and `/feedback` remain visible but disabled until Threading
can update its retained state atomically; safe commands are sent verbatim as prompts. Tool kinds
map onto `ToolIdentity`, complete tool updates attach results, plans become `runPlanUpdated`, and
`session/request_permission` is answered through the same `PermissionBroker` used by Codex.
Threading advertises no filesystem or terminal client capability because it implements neither;
Grok continues to execute its own tools. Its HTTP MCP capability does let `session/new/load` carry
the per-session Threading endpoint without changing the project's or user's persistent Grok
configuration.

## Composer commands and skills

Commands are a live transport capability, not a list copied from either CLI. The optional
`ComposerCapabilityProviding` protocol exposes provider-neutral metadata — stable id, provider
name, description, argument hint, aliases, `/` or `$` trigger, availability, and whether the
action is a model turn or a session command. `ConversationStreamSession` deliberately does not
require it: another provider can ship ordinary native chat first, then add discovery without a
provider switch in `PromptView` or `ConversationViewController`.

**Availability is one value, not a flag beside an optional.** `ComposerCapability.Availability`
is `.available` or `.unavailable(reason:)`, and the reason is required rather than optional.
The pair it replaced — `isEnabled: Bool` next to `unavailableReason: String?` — admitted two
states nothing could render: disabled with no explanation, where `PromptCompletionView` greys
the row and shows a blank line in place of the description it substitutes the reason for; and
enabled *with* a reason, where the row offers an action and explains why it cannot be used.
All four producers (Claude's unsafe-command policy, Codex's disabled skills and its
terminal-only commands, Grok's terminal-only commands) had to hold the two in step by hand, and
three wrote the same `enabled ? nil : reason` ternary to do it. `isEnabled` and
`unavailableReason` survive as computed properties, so every call site that only asks those two
questions was untouched; only the four producers changed. The remote DTOs keep two flat
JSON fields — that is a wire shape the client reads, and it is deliberately not this enum.

The composer owns only the leading token. `ComposerCapabilityResolver` matches that token and
leaves everything after its first whitespace opaque; quotes, paths, flags, and a second slash
are never re-parsed or rebuilt by Threading. Disabled or stale ids are checked again by the live
transport at dispatch. Unknown `/text` remains an ordinary prompt instead of becoming an
app-owned command language. For Claude it is also kept byte-for-byte at the start of a remote
submission: the shared-chat participant envelope must not move the slash away from column zero
and silently turn a future command or MCP prompt into prose. Codex has no raw slash fallback, so
its unknown slash-shaped prompts retain the participant envelope and attribution.

Claude's persistent process receives a control `initialize` request before its first prompt.
The nested response supplies rich command metadata; `system/init` supplies the session's
authoritative `slash_commands` and `skills` membership, and `system/commands_changed` replaces
the catalog while the process is alive. The changed payload has no kind field: memberships
already learned from `system/init` survive a replacement, removed names are discarded, and new
names are classified as the dynamically discovered skills the event represents. Before the
first `system/init`, the initialize-only list is necessarily provisional — the CLI exposes no
command/skill discriminator there. Those rows retain a command badge but are temporarily
eligible for `/skills`, so opening-session skills remain discoverable without falsely claiming
that every slash row is a skill. Authoritative membership replaces that provisional eligibility
as soon as `system/init` arrives. An opening prompt may arrive during this handshake, so the
session accepts and holds one prompt until initialization succeeds, fails, or reaches the
existing control timeout. This avoids a second probe process (which would run hooks and discover
a different session) and avoids losing the first turn. Claude executes a selected action by
sending the exact `/name arguments` text back through its ordinary stream. Successful commands
such as `/context` can return their only useful text on the terminal `result`; the timeline adds
that result only when the turn did not already produce an assistant message.

The live Claude catalog is dispatch authority, but not unrestricted UI authority. Internal
handoff rows (`/__remote-workflow`, `/workflow-launch-exec`) are omitted. Commands that would
change the provider's session, transcript, cwd or process ownership behind Threading's retained
state — `/clear` and its aliases, resume/fork/rewind/background families, and similar lifecycle
commands — remain visible but disabled with a Terminal explanation until an atomic native
mapping exists. The same gate covers commands with an interactive, external or sensitive side
effect such as heap dumps, feedback uploads and cloud reviews. Command membership also does not
decide presentation: measured agent-work commands such as `/review`, `/security-review`,
`/code-review`, `/doctor`, `/verify` and `/run` are ordinary user turns even though Claude does
not classify them as skills. A skill name cannot override the lifecycle/sensitive gate because
Claude's raw slash resolver ultimately decides which colliding entry runs. Conversely, an
unknown non-skill name defaults to a visible user turn: this preserves legacy `.claude/commands`
and future prompt workflows without requiring Threading to know their names in advance; only a
small measured set of immediate CLI/session controls renders as a muted command notice.

Codex app-server has no general slash-command catalog. Threading therefore enables only the
native operations it can map without pretending to emulate the TUI: `/review [instructions]`
uses `review/start`, and `/compact` uses `thread/compact/start`. The latter response is only an
acceptance; the composer remains Working until the standard `turn/completed` notification
settles the compaction. `skills/list`, scoped to the conversation checkout, provides `$` skills;
`skills/changed` invalidates and reloads that list. A response is accepted atomically only for a
normalized exact cwd match and an error-free scan; a wrong, empty, partial, or malformed response
keeps the latest good catalog rather than borrowing another checkout or erasing working skills.
A selected skill sends both the literal
`$name task` text and the recommended structured `{type: "skill", name, path}` turn input. The
private path is retained only inside `CodexStreamSession`.

Codex's documented TUI vocabulary is retained separately as an **expectation catalog**, pinned
to the locally verified CLI/docs version. Known commands such as `/model`, `/permissions`,
`/diff`, `/usage`, `/goal`, `/fork`, `/archive`, `/mcp`, `/apps`, `/plugins`, `/hooks` and the
terminal appearance commands appear disabled with a Terminal explanation instead of falling
through to the model as ordinary prompts. This catalog never grants execution: app-server RPCs
such as `thread/fork`, `thread/name/set`, `thread/rollback`, `thread/goal/*`,
`account/usage/read` and `mcpServerStatus/list` are candidates for explicit mappings, and each
graduates only with response, lifecycle and retained-state handling. `/status` is the first
shared app-owned fallback: when the provider has no enabled command, it reports Native Chat's
provider, model, run state and latest context reading locally without opening a model turn.
The reference snapshots are the official
[Codex slash-command guide](https://learn.chatgpt.com/docs/developer-commands.md?surface=cli)
and [Claude Code command reference](https://code.claude.com/docs/en/commands); runtime discovery
wins whenever a provider exposes it.

`PromptCompletionPresenter` is a non-key child surface in the conversation window, so the text
view keeps first responder. Up/Down move, Tab or Return inserts, Escape closes, and Return is
left to an active IME while it has marked text. `/skills` is an app-owned catalog filter rather
than a provider prompt. It appears only when the live catalog contains skills and is resolved
before transport dispatch. Provider metadata is normalized before it becomes retained UI state:
at most 256 entries and 64 KiB of bounded presentation fields survive, and one query materializes
at most 64 AppKit rows. A catalog-kind filter runs before that row limit, so a large command set
cannot crowd every skill out of `/skills`. Identity fields are rejected rather than truncated,
so a visual bound can never change which provider action runs. Pointer selection commits on
release inside the row, and disabled reasons are the same text drawn and announced by
accessibility.

Remote clients receive the same bounded, presentation-safe catalog in conversation snapshots
and replacement deltas. Skill bodies, local paths, and provider credentials never cross the
wire; a mobile submission is resolved again against the Mac session's current catalog. The iOS
composer uses the shared `RemoteComposerCompletionQuery` for `/` and `$`, exposes the complete
catalog from its plus button, and handles `/skills` locally as the same skill filter. Catalog
fields are capped independently of transcript rows so a provider-controlled description cannot
push a WebSocket beyond its high-water limit.

Both transports expose **subagent rendering** through the same provider-neutral path, including
their terminal surfaces. `SubagentSessionState`, owned by `AgentRuntime`, keeps a session's
`SubagentTimeline` outside either disposable renderer. Switching Native → Terminal (or back)
therefore terminates the old process but preserves its child navigator, transcript paths,
progress, and selected-child data rather than rebuilding an empty timeline.

Each child keeps its lifecycle and its own ordinary `ConversationTimeline`. The parent transcript
therefore stays the parent's, and neither the native conversation nor terminal inserts child
navigation above its content. Working/done counts instead occupy their own segment in the
top-right session status card, beside branch/diff state. That segment is a separate hit target:
Git state still opens Review, while child state opens one ephemeral **Subagents** tab in the
session's display pane. `SubagentTranscriptViewController` owns the complete child navigator
and the selected transcript together; switching its rows routes selection back through the
session host. A live parent renderer owns provider transcript loading; after that renderer exits,
the host selects in `AgentRuntime`'s retained state and uses the descriptor-backed loader, so the
corner receipt and an open navigator do not become inert on the dormant screen. It uses
`ConversationRowView`, so child markdown, thinking, tool calls, results, and notices use the
same native rows as the parent rather than a log-shaped second renderer. Adjacent tool calls keep
their chronological position but start behind one `N tool calls` disclosure; opening it reveals
the ordinary individually-expandable tool rows. New events update that controller only while
its tab exists; closing the tab is respected and later activity does not reopen it.

The selected child transcript is itself a view-based table. The navigator, cheap presentation
identities and parsed Markdown block models remain addressable, while AppKit creates only the rows
around the viewport. Collapsed tool disclosures do not hide prebuilt rows; they omit those row
identities until expansion. Long assistant answers are also split at Markdown block boundaries,
so revealing a large report near the bottom does not attach one document-sized constraint tree.
Selection and tool/user disclosure state live in the controller and survive row recycling.

A navigator row only carries a chevron when opening it reaches a transcript — rows already
replayed, a provider file on disk, or a child still running, which is the one case where "has
not arrived yet" is the truth rather than a permanent state. `SubagentSummaryItem` carries the
answer as `canOpenTranscript` because the component cannot work it out: a live child streams
rows it has no file for, and a finished one may name a path the provider never wrote. A row that
leads nowhere keeps its place in the list and says so, indented to the chevron rows' ink via
`ThemedButton.plainTitleLeadingInset` so a mixed list is not ragged. The same distinction picks
the detail pane's notice, so a finished child stops claiming a file is on its way. See
[`session-activity.md`](session-activity.md) for the hook reports that made empty rows possible.

Codex app-server reports child `thread/started`, `thread/status/changed`,
`collabAgentToolCall`, and `subAgentActivity` events with real thread ids.
`CodexSubagentEvent` translates those into `SubagentEvent`, including the child's complete
structured item stream.

Claude is launched with `--forward-subagent-text`. Forwarded assistant/user lines carry a
non-null `parent_tool_use_id`; `ClaudeSubagentEventAdapter` routes those lines into the child
timeline before the ordinary parent parser runs. The forwarded content is still ordinary
`stream-json`, so child text, thinking, tool calls, and tool results all pass through the same
`StreamEvent` parser as the parent. A nested Agent tool both remains visible in its caller's
transcript and discovers the next child with the caller as its parent.

Task/Agent tool calls supply the descriptor, foreground tool results finish synchronous
children, and background launch receipts remain working until their lifecycle notification
arrives. Current Claude releases report `task_started`, `task_progress`, `task_updated`,
`task_notification`, and `tool_progress`; the typed wire adapter merges their runtime task id,
summary, current tool, elapsed/duration, tool count, token count, and background state. Older
XML `<task-notification>` messages remain a compatibility fallback. The original Agent tool-use
id stays the UI identity even when a background receipt or lifecycle event introduces an
internal `agentId` or `task_id`. Explicit non-agent jobs such as `local_bash` are rejected from
the child timeline.

`SubagentReportingConversation` is an optional live capability implemented by both native
transports, rather than provider cases in the view. Terminal mode receives `SubagentStart` and
`SubagentStop` from the same routed Claude/Codex lifecycle hooks that report turn boundaries.
Those reports provide provider child id, role, final message, and durable transcript path.
`SubagentUsageReader` then reads the child's own token records: Claude through the stable usage
index, Codex by summing per-request `last_token_usage` after the child communication boundary
instead of misattributing the copied parent `total_token_usage`.

Claude also implements `SubagentHistoryConversation`.
Its `<session>/subagents/agent-*.meta.json` files provide a cheap hierarchy index: tool-use id,
parent agent id, role, and description without reading every transcript. The index
adds the first and last JSONL records to recover the prompt, ordering, and terminal state. A
selected child's JSONL is then loaded lazily through the ordinary `StreamEvent` replay path,
with the same rolling cap as the parent conversation. Sessions from older Claude versions that
lack metadata still appear under their agent id as top-level children.

The compact navigator is persisted per session under Application Support ▸ Threading ▸ Subagents.
It stores descriptors, terminal states, progress, and recent activity, not duplicated child
conversation rows; the provider JSONL remains the full-history source. On app relaunch an
unfinished row becomes Stopped because its old process cannot still be observed. Claude can
also rebuild its hierarchy from the provider index. Codex cannot rediscover children absent
from Threading's snapshot because app-server exposes no durable child index, but children observed
by hooks or app-server are restored from the snapshot and their transcript paths still drill in.

A transcript path is durable routing metadata, never a display-name fallback. Rows prefer the
provider's nickname or role and otherwise use a short agent id; a folder action exposes a
verified regular transcript file through Finder without printing its private absolute path.
Lifecycle fallback messages also cross a presentation boundary before persistence. One measured
Claude `last_assistant_message` arrived with a leading `<analysis>` envelope, so that exact
compatibility spelling becomes a localized **Reasoning** line, complete or truncated. It is not
an XML protocol: Claude's thinking stream is typed, and the measured corpus contains no
`<thinking>` or `<final>` assistant envelopes, so those and all other angle-bracket text remain
untouched.

The Claude transport was measured around four constraints before it was written, and re-probed
against CLI 2.1.220 before the gate was opened — the flags, the multi-turn persistence and the
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
identifier is the UUID Threading minted.

For either native transport, a request is shown **inline in the conversation that raised it**,
as a `PermissionRequestView` card (`ConversationViewController.presentPermission`),
not a window-modal sheet. A sheet was the wrong shape: it seized the whole window for a decision
belonging to one session and gave no clue which session asked when several were running. The card
sits in the thread, keeps its place as a record of what was chosen after it is answered, and
carries the edit diff for edits. The modal sheet survives only as a fallback for the impossible
case — a request with no live conversation.

Requests are shown **one at a time**: an agent can fire several tool calls in a turn, but
a stack of cards is answered out of context, so they queue and the next appears only once the
current one is decided (`permissionQueue` / `activePermissionCard`, `showNextPermissionIfIdle`).

A pending Claude request in an **off-screen** session raises the sidebar's attention dot: a
native session reports `activity` through `AgentRuntime` alongside terminal sessions, returning
`.needsAttention` when anything is waiting and the session is not visible (`isVisible`, set by
`setVisibleSession`). On screen the card is the cue, so no dot. `terminate()` denies the active
card and every queued request, so a session that goes away does not leave the CLI blocked on the
hook's timeout.

`PermissionPolicy` decides which tools are worth interrupting for, in Swift rather than in the
hook's matcher or app-server request handler. The read-only set is a short **allowlist**, so a
tool added in a future release prompts rather than slipping through unasked. Claude reaches the
broker through its blocking `PreToolUse` hook; Codex app-server approval requests are answered
over the same JSON-RPC connection.

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
from whatever each CLI reported, so a transport that streamed reasoning could flip to
"Thinking…" while one reporting only completed reasoning stayed on "Working…": one wait,
described two ways, for a reason no user could see. A word drawn where the turn starts asks
neither CLI anything. `thinkingDelta` now moves no status at all, and reasoning still lands as
its own row when the message finishes.

Beside the word, a **dotted orb spins while the turn is in flight** (`WorkingOrbView`, the
`ThinkingOrbs` dependency). It is shown only for the `working` status and hidden otherwise;
in the status `NSStackView` a hidden arranged view detaches, so an idle "Ready" sits flush at
the leading edge rather than behind a reserved gap, and the orb's own display link idles the
moment it is hidden. It draws in the theme accent — see the Dependencies note on the `tint`
fork — so it belongs to the current app theme rather than drawing plain black-on-white.

The checkout's floating status card becomes a **run receipt** over the same interval, and only
here: a terminal session's CLI already draws that state itself, so the card stays the branch card
there (see `git.md`). Plans are reduced to provider-neutral `RunProgress`, but the two live
protocols reach it differently. Codex app-server's authoritative `turn/plan/updated`
notification replaces the complete ordered snapshot and uses `pending` / `inProgress` /
`completed`. Legacy `update_plan` and Claude `TodoWrite` tool calls also carry complete lists.
Current Claude releases instead emit `TaskCreate` and `TaskUpdate`: `RunProgressReducer` holds a
create by tool-use id until the matching `Task #<id> created successfully` result binds its
stable task id, then applies status changes and deletions incrementally. That is the same
reconstruction Claude 2.1.220 uses internally, and because it lives in `ConversationTimeline`
the JSONL replay path gets identical behavior without a second parser.

One active item becomes `Step n / total`. More than one active Claude task is a task graph, not
a defensible linear step, so the receipt says `completed / total done · active active` instead.
`ConversationTimeline` reports either form as a change and the controller exposes it to the
container without handing provider arguments to a view. An explicit empty plan clears the
fraction; no structured plan means `Working…`, not a guessed one.

Child conversations use the same reducer. `SubagentTimeline` retains each child's latest
`RunProgress` change and prefixes it to the existing telemetry line in both the parent
navigator and selected-child header. Codex child `turn/plan/updated` notifications and Claude's
forwarded task tools therefore render identically, without leaking into the parent's receipt;
terminal or completed child state clears the label.

Claude gives the same child two identities on the two surfaces: terminal hooks report
`agent_id`, while native metadata reports the spawning tool-use id. The metadata index carries
the former as an explicit alias, and `SubagentTimeline` persists and resolves that alias so a
renderer switch cannot duplicate the child. Codex's app-server `agentPath` is different again:
it is a logical collaboration address (`/root/...`), not a rollout filename, and is never
offered to transcript replay. Only a verified regular file supplied by the lifecycle hook is
loadable; adding that path later retries an already-selected child's drill-in. Replay caches
the file's size/modification signature rather than only the child id: empty reads get bounded
retries, a file that grows is read again, and its conversation is replaced atomically so a
partial first read cannot either freeze or duplicate the final transcript.

The receipt's file and line totals do not come from tool calls. A shell command, an MCP tool or
a subagent can edit without producing an Edit block, so counting structured tools would be a
plausible lie. `GitChangeMonitor` keeps watching the checkout and independently rebuilds the
same card after each coalesced FSEvents burst. Plan and git updates can therefore arrive in
either order, and either refresh preserves the other half.

Native activity now follows the **turn**, not the transport process:
`ConversationViewController.isTurnInFlight` enters on submit and leaves on the terminal turn
event. Both native transports keep their process alive while idle, so `stream.isRunning` cannot
answer whether either is actually working. Feeding the real working edge through the existing
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

Three Claude record kinds are skipped during **parent disk replay**, and each would otherwise
read as nonsense there: `isMeta` (text the CLI injected on the user's behalf, never typed),
`isSidechain` (subagent threads, which belong to an Agent run rather than this conversation),
and everything that is not `user`/`assistant` (mode changes, titles, file snapshots). Claude
child history is reconstructed separately from the metadata index described above, and only a
selected child pays the cost of parsing its JSONL. Both parent and selected-child replay use a
*rolling window* keeping the newest turns — what matters about a resumed conversation is how it
ended.

`isMeta` is necessary but not sufficient. Claude 2.1.220 also persists several provider-owned
records as ordinary external user messages. `ClaudeTranscriptUserRecord` is the shared boundary
for parent and selected-child replay: complete `<task-notification>`, local-command output and
reminder envelopes are suppressed; a complete command triple becomes one muted
`/command arguments` notice without losing non-empty arguments; and a fork child's leading
`<fork-boilerplate>` is removed while the real task after its closing tag is retained. Unknown or
incomplete envelopes remain literal user text. This is an allowlist of measured record shapes,
not a general XML stripper.

### References and review comments

Context attached to a Chat turn has one provider-neutral model:
`ConversationContextAttachment` is either a reference or comment, sourced from a message, code
line, or attachment. It carries a short title and bounded excerpt, an optional project-relative
locator and line range, and the human's comment when it is an instruction. The same value stages
in `PromptView`, appears as a receipt on the sent message, crosses RemoteKit, and is recovered by
transcript replay. Claude, Codex, and Grok therefore cannot drift into three UI or persistence
shapes.

Every native transport ultimately accepts a text turn, so `ConversationPrompt.transportText`
appends one versioned, sorted-JSON `<threading_context_attachments>` envelope after readable user
prose. The provider sees the referenced material and instruction; the timeline keeps the typed
sidecar and does not paste it into the editable bubble. A reference/comment-only submission gains
a short readable instruction before transport. Replay hides the envelope only when its complete
closing marker and bounded JSON decode successfully; malformed or hand-written markers remain
literal user text. The boundary admits at most 32 receipts, bounds each field, caps the envelope at
96 KiB, removes duplicate ids, and rejects malformed remote values rather than partially sending a
different prompt.

The entry points use the same staged receipt rail:

- each user or assistant message offers **Add … to chat** and **Comment…**;
- a Git Review or edit-tool diff line offers **Add line to chat** and **Comment on line…**;
- a Git Review file, including an image comparison, can be referenced or commented on as a file;
- the Attachments pane can stage or comment on its selected item, and a composer image thumbnail
  offers the comment action directly.

Code anchors use the rendered line's new number, falling back to its old number for deletions.
Paths are project-relative when they belong to the checkout; attachment-store paths never expose a
machine-private absolute path. `ConversationContextRailView` groups a review batch into reference
and comment count chips, with details and removal behind its themed menus. The same counts are
included in iOS and browser conversation snapshots. OpenCode remains outside this path because it
currently has only the terminal surface, not Threading's native composer.

## Conversation Rendering

A cross-runtime destination begins with a retained **Context handoff** row before its replayed
turns. It shows the compact provider/model path, falls back to the runtime name when no model was
reported, and makes the direct source endpoint a navigation action while that session still
exists. The complete retained path also appears in the sidebar hover card, which is how
terminal-only OpenCode exposes the same provenance without drawing over its TUI. The row is part
of `presentationItems`, so replay virtualization, theme changes and scroll restoration treat it
as conversation chrome rather than as a synthetic user message.

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

**A settled turn folds behind one line** — "Worked for 42s" (`TurnFoldView`,
`Change.turnSettled`). This finishes what quieting the tool rows started: twenty quiet rows
are still twenty rows, and t3code's fold is the finished form — once a turn's terminal event
arrives, everything between its user message and its final assistant reply hides behind the
fold, so the conversation reads as its exchanges. The rules that came with it: an
*interrupted* turn stays expanded so the user keeps their place — the next turn folds it, and
it reads "Stopped after 42s" rather than claiming to have worked; the running turn never
folds; a decided permission card stays visible through a fold, because it is the record of
what was allowed. Folded work remains in the timeline but not in the live view hierarchy:
merely setting `isHidden` kept every nested tool and Markdown constraint in the window's layout
engine, so scrolling a settled conversation still laid out work that was not on screen.

The transcript is now a view-based `NSTableView`, not one retained `NSStackView` chain.
`presentationItems` owns the complete cheap ordering as stable timeline, divider, fold, card and
streaming identities; AppKit owns only reusable row hosts around the viewport. Timeline rows build
their Markdown/tool view when a host requests them and release it when that host is recycled.
Tool, long-user-message and turn disclosure state lives in controller sets rather than in a
recyclable view, so returning to a row restores what the user opened. Permission and changed-files
cards are the small deliberate exception: their live interaction state remains retained as a
presentation item, but an off-screen card is outside the attached constraint graph.

A collapsed turn removes its intermediate timeline identities from the presentation and inserts
one fold identity; expansion puts those identities back and collapse removes them again. During
replay every event mutates only the timeline and presentation model, followed by one table reload,
so a successful, interrupted or unfinished history no longer requires a retained native view for
every presented row. Exact minimap navigation resolves the target by timeline identity even when no
target view exists, lands using the table's estimated/cached row geometry, and corrects after the
target materializes. This keeps exact-row navigation without restoring the old full-history layout
chain.

Cold tool rows stop at their collapsed header. A result label or edit `DiffView` is constructed on
first expansion, reused while that materialized row closes and reopens, and released with the row
host. The table's measured-height callback validates the table row and stable presentation identity
captured when the host was configured; scanning the full presentation for each of a viewport's
measurements made an exact jump grow with transcript depth even though its native view count did
not.

The extension composition seam is similarly pay-for-play. A user, assistant or tool row whose
customization resolution is empty keeps its native subtree directly instead of receiving a
container, composition host and observer that immediately return that same subtree. One controller
observer reloads the visible viewport only when an extension event changes whether a row needs a
wrapper; an already-customized wrapper handles content-only refresh itself. Permission cards remain
wrapped even when empty because they are rare retained interactions which must acquire late
customization without reconstructing or losing their decision authority.

Replay also has no table row to invalidate until its one final reload. A result arriving during
reduction therefore clears only the diagnostic height mirror; searching the growing presentation
for a non-existent materialized row made generated 1,000-turn histories quadratic. Live timeline
rows resolve through the identity index, and the streaming placeholder resolves directly at the
tail, where it remains until the authoritative completed message replaces it. Those lookup rules
keep result attachment and token updates independent of transcript depth without changing row
lifetime or exact navigation.

The facts live in the model:
`Turn` carries `endIndex`, `finalAssistantIndex` and `duration`, and durations are retained
per turn from `.turnFinished` (they used to pass through to the status line and be
discarded). **Replay now emits `.turnFinished` too**, deriving each turn's length from the
record timestamps both CLIs already write — the same events as live, so a resumed
conversation folds identically and tool calls that never reported back settle as "stopped"
instead of reading "running…" forever.

**A settled turn also leaves a changed-files card** (`ChangedFilesCardView`,
`ChangedFilesTree`) — t3code's per-turn summary, wired to machinery Git Review already owns:
the same immutable tree baseline `GitTurnBaselineStore` captures before provider admission,
read through the same `GitReviewReader.lastTurn` request, so the card and the review
pane cannot disagree about what a turn touched. The tree is a pure derivation with its own
tests: single-child directory chains compress into one `a/b` row, ±counts roll up through
ancestors, directories precede files and both sort alphabetically. It auto-expands only for a
small turn (≤ 5 files and ≤ 200 changed lines — t3code's thresholds, computed once);
otherwise every directory starts folded so a wide sweep is a line per scope, not forty rows.
Each directory row discloses its own subtree; the header offers Collapse all and **View
diff**, which opens Git Review on the Last Turn scope — and is therefore withdrawn from a
card the moment a newer turn is accepted, before its new baseline replaces the old one.
Live turns only: a replayed turn's baseline is long gone, and diffing today's checkout
against it would attribute later work to an old exchange. An empty diff leaves no card.

**A long user message collapses behind a fade** (`UserMessageBubbleView`,
`ConversationDefaults.collapsesUserMessage`) — past 600 characters or eight hard lines, the
bubble caps at eight rendered lines with an alpha-mask fade over the tail (a mask on the
text, not an overlay, so it works on any bubble fill — and no theme colour becomes a layer
colour: the mask is alpha only). "Show full message" expands in place; Copy always copies
the whole message, because the visible prefix is a view decision, not the content. The
thresholds are t3code's. The user wrote the message — drawn in full, a pasted log drowns
the answer it was written to get. The fade's direction was wrong on the first cut (the
opening line dissolved) and only the render pass caught it: the label's backing layer takes
the hierarchy's flipped geometry, so unit-point y = 0 is the first line.

**The status row carries a context meter** (`contextLabel`, `TurnStatusText.context`) — how
full the model's window is, which is a different fact from the account usage pill's quota.
Readings ride `TurnMetrics` on `.turnFinished`, so live and replay share one path: Claude
sums the four `usage` fields (its `input_tokens` excludes cache reads, so the parts are
summed, never one trusted alone) and states no window, so its reading is absolute tokens;
Codex reports `model_context_window` beside its counts, so its reading is a percentage,
tinted warning past 90% — t3code's red-donut rule. Two traps the numbers set: Codex's
`total_token_usage` is cumulative across the session and exceeds the window on any long
conversation — `last_token_usage` is the context figure — and a Ready status that carries no
metrics (the post-replay reset) must not blank a reading that still holds, so the view
retains the newest reading apart from the status.

**Effort rides the same metrics, and the transcript is more authoritative than the setting.**
`AgentModels.defaultEffort` reads the account's config, which is the only answer available
*before* a turn runs and the wrong one afterwards: it cannot see a mid-session `/effort`, so a
replayed conversation reported its launch-time value for every settled turn. Both CLIs record
what each turn was actually given — Claude stamps `effort` at the top level of every assistant
record, Codex writes `payload.effort` on a `turn_context` record and restates it under
`thread_settings` when settings are applied — and `TranscriptReplay.effortReading` takes it
beside the context reading, before the event mapping can bail, because `turn_context` produces
no row at all. Sidechains are excluded on the same rule as the context reading: a subagent
running at its own effort is not what the user's turn ran at. The value carries across turns,
since a turn that restates nothing ran at whatever the last one did — an empty string is
therefore not a reading, or it would erase a real inherited value with something no chip can
name. The same reading labels inherited effort in either composer. Claude's installed CLI
publishes one session-level set (`low`, `medium`, `high`, `xhigh`, `max`), which `AgentModels`
attaches to every Claude model option; Codex continues to take per-model levels from its own
cache. That is enough to choose Claude effort before launch and emit `--effort`, but it is not
evidence of a live `set_effort` control request. The Claude reply chip therefore stays hidden
while the Codex app-server, which implements `ReasoningEffortConfigurableConversation`, may
change the next turn.

**Auto-scroll is a mode, not a reflex** (`ConversationAutoScroll`, the state machine tested
apart from the scroll view). The naive version — pin to bottom on every appended row, result,
and streaming delta — is what this replaced, and it is the version t3code shipped and then
filed a bug against themselves (#3925): programmatic scrolls indistinguishable from gestures,
so the pin fought the reader. Three modes: *following* (new content scrolls into view),
*anchored* (entered on every send — the sent bubble scrolls toward the top and holds while the
reply streams in below; no blank space is reserved under short content, the clip view's own
clamp does the work), and *free* (entered only by the user's hand). Gesture detection needs no
generation counter here: AppKit routes only real gestures through `scrollWheel` (the
`ThemedScrollView.onUserScroll` seam) and the live-scroll notifications (scroller drags), so
our own `setBoundsOrigin` can never release the pin. A bounds change within
`gestureAttribution` of the last gesture event re-derives the mode — near the bottom re-pins,
anywhere else frees — and momentum events keep refreshing the window, so a flick stays
attributed to its end. A minimap jump frees; a finished replay lands at the bottom and follows.

### iOS conversation boundary

The iOS conversation is a UIKit route, not a SwiftUI composition around a UIKit timeline.
`RemoteConversationViewController` owns the virtual collection, composer, command/skill results,
presence, input authority, submission receipts and keyboard constraint. It subscribes to the
connection, notification preferences and active host directly, coalescing changes onto one main
queue render. Draft and viewport continuity still use the host-and-session-scoped store; changing
the rendering owner did not change which client owns that working state.

The app and scene lifecycle are UIKit-owned so a native route can start without constructing a
root hosting graph. The dashboard and screens not yet migrated are intentionally contained in one
`UIHostingController`; the conversation stress route enters a native navigation controller
directly. A hosted `UIViewControllerRepresentable` remains the compatibility boundary when the
current SwiftUI dashboard navigates into a session. Rare modal work may still host SwiftUI—the
attention-recipient sheet does—but no hosting transaction participates in conversation cold open,
scrolling, typing or submission on the direct route.

Do not anchor the cold composer to `UIKeyboardLayoutGuide`. On the measured simulator that caused
UIKit to load and initialize its text-input tracking coordinator while attaching the first window,
adding about 108 ms before paint. Keyboard frame notifications update the safe-area bottom
constraint instead; the keyboard demo verifies the same layout behavior when input is actually
requested.

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
  narrow for a gutter, and the view hides. Threading is a three-pane window and the conversation
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

The rail follows the same rule. Stable user-row identities and compacted user/assistant preview
strings are cached once when their immutable source enters `ConversationTimeline`; a turn's extent,
chosen conclusion and duration are still derived from the canonical rows. Replay installs the
complete rail once at its boundary. Live traffic replaces only the settling tail preview and
appends one new mark for the next user turn. Besides making a 1,000-turn append independent of
history depth, settlement now updates the current hover preview immediately instead of leaving it
answerless until another question arrives.

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
them out as PNGs, light and dark (`THREADING_RENDER_OUT` to redirect). **This is what makes the
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

The reply composer is the same `PromptView` used for a session's opening message. Pasted or
dropped images therefore appear as removable thumbnails above the text on both surfaces; only
when the message is sent are their quoted file paths appended for the agent transport. This
applies to follow-up messages only under native rendering — terminal sessions keep the agent
CLI's own composer.

It differs from the opening composer in one way, `PromptView.SubmitPlacement.footer`: the model,
mode, effort and speed chips and the context meter sit on a control row **inside** the box, with
the send closing that row. They edit the next message, so they belong to it. The line above the
box is narration only — the working orb, the word for the turn in flight, and after it what the
last turn cost (`TurnStatusText.ready`). Splitting the two is the point: everything the user can
change is in the box, everything the session is telling them is above it. Before the split both
lived on one strip between the conversation and the input, which sized itself to its content and
so left the controls clustered at the leading edge of an otherwise empty row.

**Model then mode then effort leads the row**, matching the opening composer wherever the
selected model publishes effort levels. Speed is reply-only, so it follows. The mode chip
is also configured *before* the model-catalog guard: a runtime that publishes no catalog — Grok
today — still has a permission posture, and the early return that hides the model, effort and
speed chips used to take this one with it.

**What choosing a mode does differs by provider, and the menu says which.**
`PermissionModePresentation` is the one place the rows, the inherit wording and the `hand.raised`
symbol are written down; the session row's menu, the opening composer's chip and this chip all
build from it, so three entrances to one setting cannot name the app-wide default three ways.
Each surface passes only its own `Timing`, which is the one thing they genuinely differ about:

- **Claude switches live.** `set_permission_mode` rides the same control channel `set_model`
  does, and the request schema is `{subtype, mode, ultraplan?}`. Driven against CLI 2.1.221 on
  the flags this transport actually launches with
  (`--print --input-format stream-json --output-format stream-json --verbose`), three requests
  down one stdin:

  ```
  → {"subtype":"set_permission_mode","mode":"plan"}
  ← {"subtype":"success","response":{"mode":"plan"}}
  ← {"type":"system","subtype":"status","permissionMode":"plan"}
  → {"subtype":"set_permission_mode","mode":"nonsense"}
  ← {"subtype":"error","error":"Cannot set permission mode: must be one of acceptEdits, auto,
     bypassPermissions, default, dontAsk, plan"}
  → {"subtype":"set_permission_mode","mode":"manual"}
  ← {"subtype":"success","response":{"mode":"default"}}
  ```

  Three things are settled by that transcript. The set is **exactly Threading's six**. The mode
  goes over as Claude's own **external** value and the CLI normalises `manual` to its internal
  `default` itself, so this app never writes that internal name down. And the channel **refuses
  in writing** — the same shape carries `bypassPermissions` on a session not launched with
  `--dangerously-skip-permissions`, and either gated mode where settings disable it — which
  `configurationChangeFailed` prints the way a rejected model id already is. So the chip never
  claims a posture the agent declined. `PermissionModeSwitchableConversation` is the seam, and
  its `mode` is **not** optional: `set_model` takes an explicit null meaning "back to the session
  default" and this channel has no equivalent, so inherit has to be resolved before it reaches
  the wire. (The `system`/`status` line above is a standing offer this does not yet take up: the
  CLI volunteers its current `permissionMode`, which would make the chip authoritative rather
  than merely consistent with the record.)
- **Codex records for the next launch.** Its posture is stated in the `--ask-for-approval` and
  `--sandbox` flags of the `codex app-server` process, and `turn/start` carries only
  `model`, `effort` and `serviceTier` — reasoning effort is read into the next turn, the
  permission mode is not. (The app-server binary does list a `turn/start.permissions` key, but
  among the `experimentalFeature/list` names, so it is a gate rather than a contract to build
  on.) Choosing here therefore writes the record and says so.
- **A dormant conversation records too**, whichever provider it is, because there is no process
  to ask.

The record-only cases append one disabled row saying "Applies the next time this chat starts.",
which is the sentence the session row's item has always meant in a doc comment and never said on
screen. The one case with nothing honest to say is inherit chosen on a live Claude conversation
with no app-wide default to resolve it to: there the record changes, the running agent keeps its
posture, and the conversation gets a muted notice saying exactly that rather than a chip quietly
reading "Agent's Setting".

Unlike the other three chips, this one is **not** gated on `stream.acceptsConfigurationChange`.
Model, effort and speed mean nothing without a live transport; a permission mode also has a
durable record that states the next launch, and the session row's own item is editable at exactly
the times this would be closed. Two entrances to one setting must not disagree about whether it
can be changed at all.

The turn rail's preview card hangs off the pane, not off the rail (`attachPreview(to:)`), and is
attached **hidden** and positioned by constraints the pointer moves. Both matter: a card is only
ever correct beside the mark it describes, and one attached visible with no active mark, holding
a frame assigned to a view Auto Layout owns, resolved to the container's origin at the next
layout pass — an empty translucent panel parked in the pane's bottom-left corner under the
composer, which is how it shipped.

`Markdown` is a hand-written CommonMark subset — headings, paragraphs, fenced code, simple
lists, GFM pipe tables, inline emphasis and code spans — because the project depends only on
SwiftTerm and this is a small scanner rather than a package to track. Parsing is a **reader
table**: each block kind is a function that either consumes its block or returns nil for the
next reader to try, which keeps `parse` a flat loop rather than a branching tower. Fenced code
is read first and verbatim, so a `*` in a shell glob is never mistaken for emphasis. The table
reader requires the delimiter row, so ordinary prose containing pipes stays prose. Code blocks
and tables draw on their own horizontal viewport; a vertical-dominant gesture over either is
forwarded to the enclosing conversation rather than being swallowed by a surface with no
vertical range. That choice is locked for the complete trackpad gesture and its momentum tail:
minor diagonal noise cannot retarget an in-flight vertical flick to a nested horizontal surface
and make the parent conversation appear to stop. Everything else is a selectable label, so
wrapping and selection come free.

Tool calls render through `ToolCallView`: a fixed-width **glyph column** (`$` bash, `→` read,
`←` write, `✱` grep/glob, `◈` search — the vocabulary a terminal user already knows), the
tool, its one-line subject, and a size once the result lands. Collapsed by default and clicked
open, because a directory listing is longer than everything said around it. The glyph and the
whole surface aren't inspiration taken loosely from opencode's TUI — they are its exact idea,
expressed in AppKit and system colours instead of a hardcoded palette, per this file's
design-system rule.

A tool row settles into an **outcome**, not just a size. The provider's error flag is
necessary but not sufficient — Codex folds exit codes into it and Claude forwards `is_error`,
yet a shell command can print `command not found` and still be reported as success — so
`ToolOutcome.classify` also sniffs the text, a t3code mechanic. The sniff is narrowed twice to
buy precision: only shell output (a `Read` or `Grep` result is arbitrary file content, where
the same strings prove nothing), and only the opening lines for the generic phrases (deeper
down they are as likely quoted output; an explicit `exited with code N` is trusted anywhere).
Failure overrides the identity glyph with a red `✗` — per-row ink is reserved for the row that
went wrong; success stays quiet, because twenty check marks down a working turn is the slab-ink
the resting-fill rule was written against, and `✓` already means Todo in that column. A turn
that ends around a call that never reported back settles it as **stopped** rather than leaving
"running…" forever — ambiguity is temporary — but the call stays in the pending map, so a
result that does arrive late still lands over the placeholder.

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
