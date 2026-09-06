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

The mode is gated behind `AgentKind.supportsNativeUI`, which admits Claude, Codex, Grok and
Cursor — and for Cursor it is the *only* surface, because its TUI and its ACP server keep
separate conversation stores.
OpenCode remains terminal-only: its TUI/resume CLI is enough for an honest terminal integration,
but native rendering still requires a measured transport and transcript replay. Neither is
inferred from terminal output or private storage.

That capability is enforced at every boundary where the invalid state could otherwise turn into
a process-lifecycle crash. `ProjectStore.setUsesNativeUI` refuses an unsupported durable mutation;
`ConversationViewController` and `AgentRuntime.makeConversation` are failable even if a damaged or
future store gets past that rule; and `AgentLauncher.streamPlan` throws a typed
`unsupportedNativeConversation` error rather than trapping. Planning and spawn failures for all
three native transports are reported through the same asynchronous, exactly-once exit callback.
The callback is deliberately deferred: invoking it inline while `start()` still owns its launch
state lets a controller tear down the session reentrantly before construction has returned.

Structured execution also crosses a separate boundary before presentation normalization. Claude's
native tool blocks, Codex App Server item notifications and ACP tool updates are handed to the
[Execution Audit](execution-audit.md) adapters before `StreamEvent` turns them into shared timeline
rows. This preserves exact native inputs/results without admitting prompt, reasoning or assistant
prose into the audit store. `ACPProviderExecutionAdapter` serves every ACP CLI rather than one
vendor: the audit category is derived from the neutral `ToolIdentity` a `tool_call` maps onto, so
there is nothing provider-shaped left for a second ACP agent to specialize.

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
 CodexStreamSession    ClaudeStreamSession    ACPStreamSession(.grok/.cursor)
 codex app-server      claude stream-json     grok agent stdio · cursor-agent acp
            │                  │                  │
            └─────────────────┴─────────────────┘
                                  ▼
                    ConversationViewController
```

The third leg is one runtime and two values: `ACPStreamSession` speaks the protocol, and
`ACPProviderProfile` carries whatever a particular CLI does differently. `.grok` and `.cursor`
are the profiles that exist today, and the transport cannot tell them apart.

Codex native rendering uses the CLI's **app-server**, not the one-shot `codex exec --json`
surface. `CodexStreamSession` launches one `codex app-server --listen stdio://` process,
performs the `initialize` / `initialized` handshake, then calls `thread/start` or
`thread/resume`. User messages become `turn/start`; model, effort and service tier are read
from the latest `ProjectStore` record into that request, so an idle conversation can change
configuration without restarting the server or changing thread id. Before a conversation has
its own Standard/Fast override, its **Follow General Setting** choice resolves the app-wide Codex
startup-speed policy onto the app-server launch; each later `turn/start` resolves the same chain,
so a conversation still following an explicit General Standard/Fast choice does not drift from
the process. Claude's Native transport receives the same startup policy in its per-session
`--settings` file and restates it over `apply_flag_settings` when the stream is ready.
The full precedence and Terminal parity live in [`sessions.md`](sessions.md#startup-speed-per-runtime-and-per-conversation).

`CodexAppServerEvent` maps provider-specific JSON-RPC notifications onto `[StreamEvent]`.
Agent-message deltas use the same streaming placeholder as Claude, completed messages become
markdown, command/MCP/dynamic/file/plan items become the same collapsible tool rows, and
`turn/completed` returns the composer to Ready. The older `CodexStreamEvent` adapter remains
for `exec --json` fixtures and one-shot surfaces, but it is not the native conversation
transport.

App-server's `error` notification is also a turn boundary when `willRetry` is explicitly false.
Depleted workspace credits have been measured ending there without a usable later boundary, so
waiting only for `turn/completed` leaves the native conversation in Working indefinitely. A
retrying error remains narration inside the open turn. When app-server emits both terminal
notifications, `CodexStreamSession` admits the first and suppresses the duplicate, including its
message-lifecycle receipt, so one provider turn still produces exactly one `turnFinished`.

Codex is also the only current runtime whose retained-conversation surface has reversible
archive semantics. `ProviderArchiveSync` uses the installed CLI's `archive` / `unarchive`
commands rather than borrowing a live `CodexStreamSession`, because a filed conversation is
normally dormant and may have no app-server process. The filesystem placement that app-server's
`thread/archive`, `thread/unarchive`, and `thread/list(archived:)` contract defines is the read
side of synchronization. This keeps Threading and another Codex client on the same account in
agreement without inventing reversible archive semantics for Claude, Grok, or OpenCode; the
complete provider distinctions, merge, and failure rules live in
[`sessions.md`](sessions.md#the-provider-archive-boundary).

### One unreadable element does not cost the list

`value as? [[String: Any]]` is all-or-nothing, and — unlike the object conversion in `JSONValue`
— it fires on ordinary provider JSON. `JSONSerialization` renders a JSON `null` as `NSNull`, so
one `null` anywhere in an array answers `nil` for the **whole** array rather than for the element:
`["c1", null] as? [[String: Any]]` is `nil`, not `["c1"]`. The same is true of `as? [String]` and
a number. The consequences were measured through the corpus in
`ProviderWireTextCorpusTests.swift`: a `null` beside an assistant's text lost the entire turn, a
`null` beside a tool result lost every result and then the record's text too, and one number in
`skills` emptied the skill membership so every readable skill was presented as an ordinary
command.

`WireList` (`WireList.swift`) is the seam, for every provider and not only the conversation path.
`objects`/`strings`/`values`/`indexed` keep the elements they can read and report what they
dropped — the site label from `WireListSite` and the counts, never the value — so an agent writing
lists this client cannot read is findable in the unified log without opening a transcript. The
logger is passed per call, so an AI provider response reports under `ai.response` and the avatar
lookup under `github` rather than everything landing in `agent`. `indexed` additionally carries the
wire's own offsets, because an entry named by its position must not be renamed when a neighbour
breaks; `values` is the dictionary form, where `as? [String: [String: Any]]` is all-or-nothing
across keys.

`objectsIfListed`/`stringsIfListed` are the same readers with one extra refusal: they also answer
nil when *nothing* in the list was readable, because a `{"commands": ["ctx"]}` must not empty a
composer catalogue that a malformed message never described. So there are three answers, not two —
nil for "not a list of that kind", `[]` for "an empty list", and, for the `…IfListed` pair, nil for
"a list with nothing of that kind in it". Recovery is right wherever the elements stand alone:
content blocks, replayed rows, the command catalogue, the ledger's copy of a message.

**Two sites keep refusing, on purpose.** `ACPStreamSession`'s permission `options` is one:
`answerPermission` maps a single human "Allow" onto the first option whose `kind` it recognises,
in `ACPDefaults.allowOptionKinds` order, so an unreadable `allow_once` would not be *missing* from
a recovered list — it would be replaced by `allow_always`, and somebody granting one command would
have granted all of them. Refusing the list whole answers `cancelled` and runs nothing, and the
refusal is logged rather than silent. `ClaudeTranscriptInterruption.statesTheMarker` is the other:
its whole classification is "one text block and *nothing else*", so recovering would make
`blocks.count == 1` mean "one block we could read" and report an interrupt nobody pressed. Both
follow `6bb2ebfb`, which kept the Codex approval arguments and the `PreToolUse` hook input strict
for the same reason — a partial request is exactly what gets approved for something it did not
say.

### ACP, and the one value that names a provider

Grok native rendering uses the public **Agent Client Protocol** exposed by `grok agent stdio`, and
the transport is split in two: `ACPStreamSession` (`ACPStreamSession.swift`) owns the protocol,
and `ACPProviderProfile` (`ACPProviderProfile.swift`, plus `ACPProviderProfile+Grok.swift`) owns
everything one CLI does differently. Grok is the value `.grok`, and the runtime never learns that
name.

`ACPStreamSession` owns process lifecycle, JSON-RPC framing, the `initialize` handshake, opening
or loading the session, prompts, cancellation, permission answers, the malformed-line counter and
the synthesized failure when the child dies mid-turn. `ACPWireAdapter` reads the standard wire
shapes — content, title, plan entries, tool kinds, tool input and result, the command catalog —
and `JSONRPCLineEnvelope.swift` holds the newline-delimited framing this shares with Codex's
app-server. ACP does not own broken-pipe signal policy: its stdin is the shared
`AgentChildProcess` parent descriptor, protected with `F_SETNOSIGPIPE` at construction so a CLI
that exits before `initialize` turns the write into an ordinary transport failure rather than a
host-process `SIGPIPE`. Codex and Claude receive the same guarantee from the same boundary.

`ACPProviderProfile` is the only place a provider is named. Its members are the display name used
in turn-failure prose, the diagnostics label used in logs and `StreamParseDiagnostics`, the
`StreamEvent.unknown` namespace prefix, an optional `clientCapabilities._meta` extension, a reader
for a model id reported outside the standard `models.currentModelId`, a reader for a command
catalog returned from `initialize`, and the host's command-catalog policy (id prefix, refused
names, refusal reason, which names are session commands rather than turns). Each exists because
Grok needs it today or because ACP sanctions `_meta` as the extension point; a member added *for
the next provider* becomes a conditional in the runtime.

Deliberately **not** profile members: the permission option kinds (`allow_once`, `reject_once` and
their `_always` pair are ACP's own vocabulary), the execution-audit adapter (its body is neutral),
`clientInfo` / `fs: false` /
`terminal: false` / `session.configOptions` / the protocol version / the MCP server list (all
Threading host policy — stating them per provider would let a CLI claim a capability this client
does not have), `steerAvailability` (a fact about the specification), and `session/new` versus
`session/load` (which follows from `ResumeState`). It is also deliberately not an `AgentKind`: a
transport able to ask which runtime it is starts answering per runtime, the comparison
`scripts/check_architecture_boundaries.sh` refuses.

A second ACP CLI is therefore one profile value plus a launch line in `AgentLauncher`. It adds no
capability claim, no transport, and no branch. **Cursor is that second CLI**, and it cost exactly
that: `ACPStreamSession(.cursor)` over `cursor-agent acp`, `ACPProviderProfile+Cursor.swift`, and
a launch line short enough to read — the executable, the hidden `acp` subcommand, and nothing
else, because Cursor's model and mode are wire state rather than launch flags. It claims
`.resume` (a session created in one process replayed in another), `.nativeUI` and
`.threadingBridge` (its `session/new` connects a wire-injected MCP server before the first
prompt), and deliberately claims no forking (`session/fork` is `-32601`), no permission modes
(its `agent`/`plan`/`ask` are a different axis from Threading's six), no preset session id, no
accounts, and nothing about transcripts or usage — that protocol carries no usage notification of
any kind. Every one of those rows cites its measurement in
[the archived Cursor ACP measurements](../archive/research/CURSOR_ACP_FINDINGS.md); nothing ships from inference.

Two Cursor facts reach beyond the profile. Its CLI opens a browser when it decides it needs a
login, so its plan carries `BROWSER=/usr/bin/true` and `NO_OPEN_BROWSER=1` through the new
`AgentLaunchPlan.environmentOverrides` — a provider-neutral field applied by
`AgentLaunchPlan.launchEnvironment()`, which every native transport now spawns through. And its
interactive TUI keeps a *different conversation store* from its ACP server, with neither able to
read the other's id, so a Cursor session has no terminal surface at all; see
[`sessions.md`](sessions.md#launch-and-resume).

Cursor also drove the three pieces of provider-neutral hardening in `ACPStreamSession`, all of
which serve Grok equally. `initialize` and the session open now carry a response **deadline**
(`ACPDefaults.handshakeTimeout`, 30 s), because an ACP agent may answer a malformed line with
nothing at all — no response, no error, and no standard-error output — which makes a framing
desync undetectable without a client-side timer; `session/prompt` deliberately has none, since a
model turn is legitimately unbounded. Tool-call ids are treated as **opaque**: one measured id
contains a literal newline, and every id path here is a dictionary key or a JSON string, which a
transport test now pins. And a tool call **this client denied** is presented as denied even when
the agent completes it with no output and never uses ACP's `failed` status — the client's own
answer is the only record of a refusal, so the emitted `ToolResult` carries `isError` and, where
the agent said nothing at all, a fixed sentence rather than an empty success.

The behaviour below was verified against Grok 0.2.118 and ACP protocol version 1. A fresh chat sends
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

`ACPStreamSessionTests` drives the runtime against deterministic `/bin/sh` agents with a *fixture*
profile rather than `.grok` or `.cursor`, so nothing it pins can be true of one vendor only. A fake handed the
wrong line exits with a distinctive status, which fails a turn instead of hanging the suite, and
every client line is recorded so an assertion reads the bytes that crossed the pipe. It holds the
regressions this split could cause: replay gating (history before `initialised`, no deltas during
it, a late `user_message_chunk` dropped), exactly-once exit, permission option selection over the
standard kinds, the stop-reason settle, catalog bounds and policy, handshake parity including the
omitted `_meta`, and framing across partial and malformed lines. `GrokACPProfileTests` keeps what
is Grok's: the `_meta` readers, the catalog policy, the end-to-end handshake recorded against
0.2.118, and byte-parity for the three transport sentences a user reads. `CursorACPProfileTests`
does the same for Cursor, and its fakes quote §10 of the findings verbatim — the four-key
`session/new` result, chunks with no `messageId`, a `toolCallId` with a newline in it, three
permission options whose ids are hyphenated while their kinds are underscored, and a rejected
call the agent reports as `completed`.

### The CLI can live in the background host

A conversation's child does not have to be a child of this process. `AgentChildProcess.launch`
takes an optional `host: PTYHostChildPlan`, and when the plan resolves, the CLI is spawned inside
`threading-ptyd` on three pipes instead — which is what lets a turn go on being written while
Threading is closed. `ConversationViewController` composes the plan once per launch, beside the
`plan` and `mcpBinding` closures and for the same reason: it is resolved at launch time, so a
dormant conversation reopened an hour later asks the current setting and the current daemon rather
than the ones that were true when the controller was built.

**None of the three transports learns about it.** They are handed the identical three
`FileHandle`s the local path would have handed them — the same `F_SETNOSIGPIPE` on standard input,
the same end-of-file semantics, the same `readabilityHandler` shape — while `PTYHostPipeLink` owns
the other three ends and relays them across the wire. So the framing, the handshake deadlines, the
malformed-line counters and the exactly-once deferred exit callbacks each of them owns are
untouched, which is the whole reason the seam is *below* `ConversationStreamSession` rather than
inside it. Each transport gains exactly two members — `isHostBacked`, and a
`detachFromBackgroundHost(by:)` that hands the child over at a quit instead of closing standard
input — and the protocol defaults both to "no", so a transport with no host-backed path and every
test double is unchanged by the background host existing.

Every way the host can be missing degrades to the launch this app performed before the daemon
existed, journalled with a structural cause. A quit hands the CLI over; **the next launch ends it
and resumes the conversation from its transcript**, because a request/response transport cannot be
rejoined half-way through a turn — the reasoning, and what that costs, is in
[`pty-host.md`](pty-host.md#why-a-conversation-is-not-reattached).

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

The new-session composer exists before any provider process, so it cannot consume that live
catalog yet. `PreSessionComposerCatalog` gives the shared `PromptView` a bounded expectation
catalog for the selected runtime and surface: documented/measured built-ins complete in the
draft, including `/loop`/`/proactive`, while account-, project-, plugin-, and skill-defined rows
wait for live discovery. One insertion, deletion, or substitution keeps a name or alias visible
after three typed characters, so `/look` can still complete to `/loop`. These expectations never
grant execution. On native launch, a leading `/` or `$` opening message waits until the
transport's catalog handshake is authoritative and then re-enters the ordinary
`ConversationViewController.submit` path. Known commands therefore take their semantic RPC or
native safety refusal; unknown text still follows the provider's ordinary unknown-command path.

Every row Threading writes itself carries a description, because the completion row reserves a
line for one whether or not there is text in it. The Codex terminal-only rows shipped with none,
so `/goal` and `/logout` drew a name, a blank line, and a right-hand label reading "Command" —
which answers nothing the person who pressed `/` was asking. The other four runtimes each had a
single placeholder standing in for their whole catalog: "availability is checked when Claude Code
starts" for ninety-two of Claude's ninety-six, one "availability is checked when the agent starts"
across Grok and Cursor, and "handled by OpenCode's terminal after launch" for all of OpenCode's.
Each of those is a sentence about Threading rather than about the command.

All five now carry the CLI's own summary in Threading's voice, read from the installed agents on
2026-08-29 rather than from documentation: Claude Code 2.1.251 through its `initialize` control
request, Codex 0.150.1 and OpenCode from their own command registries, Grok 1.0.5 from its ACP
`initialize` and slash table, Cursor from the `available_commands_update` it pushes. Only Cursor's
builtins are named here, because the rest of that push is the account's own commands. A test fails
on a pre-session row whose detail is empty, is only the name again, or is still one of those
placeholders — so a name added to a policy set without copy is caught rather than shipped. The
live catalogs still replace all of it, and Codex's terminal-only rows are the same values in both,
so a description added there is not missing once app-server is up.

Reading the CLIs also answered a question the placeholder had hidden. Grok's pre-session names
come from `hostOnlyNames ∪ sessionCommandNames`, but `hostOnlyNames` is a *denylist* applied to
whatever the live catalog advertises — it may name a command the current CLI no longer has, which
is harmless as a refusal and wrong as an expectation. `/permissions` is one: Grok 1.0.5 advertises
neither the name nor a doc entry and offers `/always-approve` instead, so the composer was
promising a command that does not exist. It is subtracted from the expectation set and kept on the
denylist in case a later Grok reintroduces it.
Ordinary opening prose is not delayed. Grok's ACP catalog is complete in `initialize`; Cursor's
arrives in `available_commands_update`, with a five-second fallback so an omitted optional
notification cannot strand the opening message. Codex's built-in slash catalog becomes available
with the opened thread; when the surface requests checkout skills, readiness includes that first
`skills/list` response so an opening `$skill` cannot race its metadata.

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

The opened thread's `Thread.name` and subsequent `thread/name/updated` notifications are the
native surface's canonical conversation-name channel. `CodexStreamSession` reports both through
the same title seam ACP uses, but marks them as provider metadata rather than transient transport
output. That authority distinction is load-bearing: it lets a Codex `/rename` replace an older
terminal caption without replacing a name the user deliberately chose through Threading.

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
corner receipt and an open navigator do not become inert on the dormant screen. It draws through
the same `ConversationTranscriptTable` as the main conversation, so child markdown, thinking,
tool calls, results and notices are the parent's native rows under the parent's placement rules
rather than a log-shaped second renderer: a rule before every exchange but the first, a lone tool
call as its own collapsed row, and a run of two or more adjacent calls keeping its chronological
position behind one `N tool calls` disclosure that opens into the ordinary
individually-expandable rows. New events update that controller only while its tab exists;
closing the tab is respected and later activity does not reopen it.

The selected child transcript is itself a view-based table — the same table type, with the
navigator and the heading as the pane's own items ahead of the rows. The navigator, cheap
presentation identities and parsed Markdown block models remain addressable, while AppKit creates
only the rows around the viewport. Collapsed tool disclosures do not hide prebuilt rows; they omit
those row identities until expansion. Long assistant answers are split at Markdown block
boundaries here — the one placement option the child turns on and the main conversation does not,
because its answer rows carry per-message wrappers and `MarkdownView` already pages inside them —
so revealing a large report near the bottom does not attach one document-sized constraint tree.
Selection state lives in the controller; tool/user disclosure state lives on the table and
survives row recycling.

A navigator row is a **selectable row**, and the row of the child on screen is drawn selected.
The rows were buttons carrying a chevron, and the chevron lied twice: it promised detail under
the row when pressing it swapped the transcript further down the pane, and on the row already
open a second press did nothing at all. Nothing said which of three finished children the rows
below belonged to, which was reported as every agent writing into one space. Now the selected
row paints the theme's selection, the way the sidebar paints the open session, and a
`SubagentTranscriptHeadingView` at the seam between navigator and rows names the child the rows
belong to (`SubagentNavigatorRowView` in [`design-system.md`](design-system.md)).

A row is pressable only when opening it reaches a transcript — rows already replayed, a
provider file on disk, or a child still running, which is the one case where "has not arrived
yet" is the truth rather than a permanent state. `SubagentSummaryItem` carries the answer as one
`TranscriptAvailability`: unavailable, openable from retained/live rows, or on disk with its
URL. The component cannot derive that state: a live child streams rows it has no file for, and
a finished one may name a path the provider never wrote. Because a Finder action is available
only in the on-disk case, navigation and reveal cannot contradict one another. A row that leads
nowhere is disabled rather than removed: it keeps its place, its facts and its ink column, and
says in words why it does not open. The same distinction picks the detail pane's notice, so a
finished child stops claiming a file is on its way. See
[`session-activity.md`](session-activity.md) for the hook reports that made empty rows possible.

The navigator is also the standing work receipt, not merely a list of provider role names.
Every bounded row keeps the delegated prompt visible, then adds the model/reasoning configuration,
provider progress and indexed usage when known, plus the latest distinct activity or result. These
are projections of the descriptor, timeline and usage snapshot already in memory; opening the pane
does not start another provider read or poll. Selection still changes only the transcript beneath
the navigator, and a page still constructs at most 40 child rows.

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
`SubagentUsageReader` then reads the child's own token records through the same strict Claude and
Codex adapters as the account ledger. Codex per-request `last_token_usage` begins after the first
child communication boundary when one exists, so the copied parent prefix is not attributed to
the child; current rollouts also retain `session_meta.parent_thread_id` as durable accounting
provenance. Claude's native tool result immediately adds its `agentId` as an alias of the spawning
tool-use id, so the live renderer can join the child JSONL's ledger identity before history replay.

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

A transcript path is durable routing metadata, never a display-name fallback. A row is named by
the provider's nickname (Claude's task description, Codex's `agentNickname`), then by the
delegated task's first line, then by the role, then by a short agent id
(`SubagentDescriptor.displayName`). The role comes after the task deliberately: Codex reports
every spawned child's role as `default`, so three children named by role were three rows of the
same word. A role that is not the name stays visible on the row's configuration line; a folder
action exposes a verified regular transcript file through Finder without printing its private
absolute path.
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
sits in the thread while the decision is pending and carries the edit diff for edits. It leaves
the presentation immediately after an answer: the tool row and Execution Audit are the durable
record, while a second copy of the prompt made the conversation read as still blocked. The modal
sheet survives only as a fallback for the impossible case — a request with no live conversation.

Requests are shown **one at a time**: an agent can fire several tool calls in a turn, but
a stack of cards is answered out of context, so they queue and the next appears only once the
current one is decided (`permissionQueue` / `activePermissionCard`, `showNextPermissionIfIdle`).
Each queued request is re-evaluated when it reaches the front. Parallel calls may all have been
classified before the first card's **Allow for Session** choice changed policy; presenting the
later cards from that stale classification contradicted both the choice and the **Auto** chip.

A pending native request raises the sidebar's attention mark whether or not its conversation is
visible: a native session reports `activity` through `AgentRuntime` alongside terminal sessions,
returning `.awaitingUser` when the request blocks an open turn and `.needsAttention` when anything
is waiting after the turn has closed. The inline card explains what needs an answer; the row mark
states that the session is waiting rather than working, so suppressing it on the selected row
would leave the spinner saying the opposite. `terminate()` denies the active card and every queued
request, so a session that goes away does not leave its transport blocked on a timeout.

`PermissionPolicy` decides which tools are worth interrupting for, in Swift rather than in the
hook's matcher or app-server request handler. The read-only set is a short **allowlist**, so a
tool added in a future release prompts rather than slipping through unasked. Claude reaches the
broker through its blocking `PreToolUse` hook; Codex app-server approval requests are answered
over the same JSON-RPC connection.

**Having nobody to ask is answered twice, at two different distances**, and the two rules live in
different files because they are answerable in different processes:

- **The app is running and this conversation has no window to ask in.**
  `PermissionBroker.decideIgnoringSystemGrant` denies with "Threading has no window available to
  ask for permission." It is the one place every transport converges — Claude's hook, Codex's
  app-server approval and ACP's `session/request_permission` all end here — so the rule is stated
  once and covers all three.
- **The app is not running at all.** Nothing converges, because nothing is reached: the hook's
  `curl` connects to neither the rendezvous nor the port. That used to print nothing and exit
  with curl's status, which is safe but *mute* — the CLI falls back to its own headless
  behaviour, which means the tool is blocked with the model told nothing, and the turn stalls on
  a refusal it cannot explain or work around. The generated command now ends in
  `|| printf '%s' '{…}'` (`MCPDefaults.hookBrokerCommand`), so an unreachable app answers with
  the same `hookSpecificOutput` object `MCPServer.routePermission` would have sent — built *from*
  `PermissionDecision.deny` rather than transcribed, so the two cannot drift — carrying a reason
  in the stdio bridge's voice: Threading is closed, this is temporary, continue without the tool.
  Exit status 0, because the status is a decision to these CLIs and only stdout should be saying
  anything.

Three properties keep the fallback from answering anything it should not. `||` binds it to the
POST's failure, so an app that replied is never followed by a second object on the same stdout.
It reaches **only** the broker command: the lifecycle hooks end in `>/dev/null 2>&1 || true`
precisely so they can never speak, and a deny printed by an observational hook would answer a
question nobody asked it. And in Codex's shared `hooks.json` the surface guard and the deny sit
inside one brace group, because `guard && post || deny` refuses every tool call in the runs the
file is *shared* with — the user's own terminal Codex sessions, which have Codex's own approval
prompt. Adding it changed that file's text once, which costs the user one re-approval; see
[`session-activity.md`](session-activity.md).

**And the second case now happens on purpose.** It was written for a CLI that outlived a crash;
with the background host a conversation's CLI outlives an ordinary quit and goes on asking for
tools with nothing behind the socket. So the typed deny is the difference between a turn that
finishes what it can without the tool and one that stalls overnight on a question nobody is there
to answer — which is why `PTYHostPipeSessionTests` exercises the fallback with no app reachable
rather than trusting that the shape is still right.

For shell execution, the tool name alone cannot make that decision. `ShellCommandPolicy` admits
only vetted reader commands and rejects every segment if an argument can write or execute. Process
lookup belongs to that reader vocabulary: `pgrep` only inspects the process table, so probes such
as `pgrep -fl xctest` proceed without raising an approval card. Cross-session messages are not a
substitute for this classification: a message to a chat waiting on permission queues behind the
blocked turn and cannot answer the card, and no agent-facing control operation grants one session
authority to approve another session's arbitrary command.

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

The native status strip and the terminal's floating status card gain a **run-plan disclosure**
over the same interval. On Terminal it is a separate compact row below the checkout name, so the
branch never disappears; on Chat it sits at the trailing edge of the status strip immediately
above the composer. Both open the same host-owned, anchored `ThemedPopover` checklist and clear
when the turn settles. Plans are reduced to provider-neutral `RunProgress`, but the live
protocols reach it differently. Codex app-server's authoritative `turn/plan/updated`
notification replaces the complete ordered snapshot and uses `pending` / `inProgress` /
`completed`. Legacy `update_plan` and Claude `TodoWrite` tool calls also carry complete lists.
Current Claude releases instead emit `TaskCreate` and `TaskUpdate`: `RunProgressReducer` holds a
create by tool-use id until the matching `Task #<id> created successfully` result binds its
stable task id, then applies status changes and deletions incrementally. That is the same
reconstruction Claude 2.1.220 uses internally, and because it lives in `ConversationTimeline`
the JSONL replay path gets identical behavior without a second parser.

The compact disclosure names the active item and its current/total position. More than one active
Claude task is a task graph, not a defensible linear step, so its summary retains completed and
active counts instead of inventing an order.
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
one rendering path. Claude reuses its content-block parser; Codex reads the typed dialogue
records from its rollout and deliberately ignores the duplicate `response_item` message copies.
`.userMessage` exists only for replay: a live turn is echoed locally as it is sent, so producing
it from the stream too would draw it twice.

**Codex has written its dialogue two ways, and the reader knows both.** Up to 0.146 a user turn
was an `event_msg` of type `user_message` and an answer an `agent_message`. 0.147 introduced an
`item_completed` event whose `item.type` is `UserMessage`, `AgentMessage`, `Reasoning`,
`ContextCompaction` or one of the tool-shaped items; rollouts of 0.147–0.149 carry either shape,
and from 0.150.1 the old events are gone (measured over 963 rollouts on one machine). Threading
read only the old shape, so for a month every newer Codex conversation replayed as tool rows with
no text — invisible in the terminal surface, and found only when a cross-provider handoff froze
992k characters of tool output and not one user message. `CodexRolloutFormat` holds the vocabulary
and the table; `codexItemEvent` maps the items. Tool-shaped items (`CommandExecution`,
`FileChange`, `McpToolCall`, …) map to nothing because the paired `response_item` records already
replay them, which is the same duplicate rule as the message copies from the other side.

**A third shape is reported, not swallowed.** `CodexRolloutFormatProbe` rides every whole-file
read (`TranscriptReplay.forEachRecordEvent`, which `replay`, the handoff capture and the tests all
go through) and compares the model-visible history against what the reader produced. Every rollout
format so far has kept one `response_item` `message` per assistant reply, because that list is the
request history the CLI sends back to the model; a file with assistant replies there and none in
the reduction is `TranscriptFormatVerdict.codexDialogueUnreadable`. The verdict is behavioural
rather than a version pin on purpose: Codex releases every few days and most leave the records
alone, so a notice after each update would teach people to ignore it. User turns do not decide
the verdict — a spawned sub-agent's rollout carries its brief as a user-role history message and
has no `UserMessage` item, and 18 measured files were that correct shape. On an unreadable file
`replay` prepends one `.transcriptNotice` naming the Codex version where the conversation should
have been, `ThreadingLogger.agent` and the `EventLog` journal record the version and the
unfamiliar item types (never content), and a handoff capture refuses with
`transcriptFormatUnreadable` rather than freezing tool output alone.
`CodexRolloutFormat.newestVerifiedCLIVersion` says which release the reader was last checked
against; bump it after running the opt-in audit in `CodexRolloutFormatTests`
(`THREADING_CODEX_ROLLOUT_AUDIT=1 scripts/test.sh fast -only-testing:ThreadingTests/CodexRolloutFormatTests`;
the variable is whitelisted in both test plans, which is how any variable reaches a hosted test)
over real rollouts of the new release, and regenerate a fixture
with `scripts/scrub_transcript.py` when a shape changed. The fixture `codex-item-completed.jsonl`
under `Tests/Fixtures/Transcripts` is the 0.151 shape; the two older Codex fixtures are the legacy
one, and `ConversationTimelineTests` holds every fixture to replaying both voices.

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
line, attachment, workspace file, or another session. It carries a short title and bounded excerpt, an optional project-relative
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
- a Git Review or edit-tool diff line offers **Add line to chat** and **Comment on line…**; in
  Git Review's TextKit renderer a text selection is how *several* lines are chosen — a
  right-click inside the selection retitles the pair **Add lines to chat** / **Comment on
  lines…** and speaks about every selected line, while a right-click outside it stays about the
  line under the pointer, macOS's own contextual-click convention. Either way the click selects
  the target lines whole, so the wash under them is the receipt's exact quote — the lines lit
  are the lines the sheet and the excerpt will carry. A selection with gaps (⌘-click on the
  gutter's `+`) stages **one receipt per contiguous run**, and a comment on it is asked once and
  staged on every run, since a receipt's line range is one contiguous span by design — see
  [`git.md`](git.md);
- a Git Review file, including an image comparison, can be referenced or commented on as a file;
- the Attachments pane can stage or comment on its selected item, and a composer image thumbnail
  offers the comment action directly;
- a sidebar session row dragged onto the composer stages a `.session` reference — the row's title,
  its Threading id as the locator, and the brief telling the agent which tool takes which id as
  the excerpt (`SessionReferenceBrief`, see [`control-plane.md`](control-plane.md)). The rail
  draws it as its own named chip rather than folding it into the reference count, because it is
  the one named thing the person just dropped; the same drop on a terminal pastes the brief as
  one bracketed line. `PromptView.onSessionReferenceDrop` is the door — nil refuses the drag,
  since a composer with no session behind it has nobody to brief the reference for.

Code anchors use the rendered line's new number, falling back to its old number for deletions;
a multi-line span anchors on its first and last displayed lines by the same rule, and its title
folds the range on as `path:12-15`.
Opening a comment from either diff carries a separate, presentation-only `CodeContextPreview` into
the sheet: normally two neighbouring rendered rows on each side, with additions/removals and line
numbers intact, and every selected row stated with the selection surface plus a leading `›`.
The preview asks its source for at most ten code rows. If the target itself is larger, it keeps the
first and last five candidate rows around one counted omission instead of building a view per
selected line. That bound belongs only to the sheet — `ConversationContextAttachment.excerpt`
continues to quote the complete selected span, so adding or sending the comment loses nothing.
Paths are project-relative when they belong to the checkout; attachment-store paths never expose a
machine-private absolute path. `ConversationContextRailView` groups a review batch into reference
and comment count chips, with details and removal behind its themed menus. The same counts are
included in iOS and browser conversation snapshots.

#### Hold it, or send it

The comment sheet is one type, `ContextCommentAlert`, for every site above, and it offers two
affirmatives rather than one: **Add to Chat** on Return parks the comment beside the prompt so
more can be staged onto the same turn, and **Send** on ⌘Return hands it over immediately.
`sendContextAttachment` sends it *with* whatever prose is already in the box rather than instead
of it — someone who typed half a sentence and then commented on the file it was about meant one
turn.

`TextPromptRequest.immediateTitle` is the seam. Two affirmatives that both answer with the field
needed a second one, distinct from `clearTitle`, which answers with nothing. The trap underneath
is that `ThemedButton.keyEquivalent` matches its character *whatever is held with it*, so the
default's Return would have swallowed ⌘Return and left Send reachable only by mouse.
`ThemedAlert.resolvedChords` restates a plain Return as an exact-match `KeyboardShortcut` for the
whole sheet whenever a sibling carries a modifier-bearing chord on the same key — which also
draws `↩` and `⌘↩` on the two faces, since a pair nobody can see is a pair nobody finds.

#### The terminal half

None of the above requires a native conversation. `SessionContextHandoff` resolves a session to
whichever surface holds its input and answers for both, so the Attachments pane and Git Review
offer the same actions to a terminal session — which is every OpenCode session, and any Claude,
Codex, or Grok session with native Chat turned off. Before this, those panes drew a **Chat…**
button that silently did nothing, and the one workflow the feature exists to remove — copy the
path, switch panes, paste it, type the sentence — survived exactly where it cost the most.

A terminal is *pasted into*, because a terminal carries text and that is the whole of its input
surface. It is handed `ConversationContextAttachment.plainText(omittingAnchor:)` — the sentence a
person would have typed — rather than the JSON envelope, which exists so a native transport can
hand the typed value back and has nothing to be handed back to here. A message's locator is
`conversation-row:3`, a private timeline id, so prose falls back to the title for `.message` and
uses the path with its line range folded on for `.code` and `.attachment`.

Two details are load-bearing. An attachment's real path goes over **first and alone**, in its own
bracketed paste, because both CLIs read one arriving paste as a unit and attach it as an image
only when the whole of it is a path — a path with a sentence after it is a sentence (see
`TerminalDrop`). And the Return that submits is deliberately late by
`TerminalDefaults.pastedTurnSubmitDelay`: both CLIs resolve a pasted image path asynchronously,
and a Return in the same runloop turn risks submitting before the picture arrives.

Whether a pane draws the affordance is `SessionContextHandoff.canReceiveContext`, which is a fact
about the agent rather than about the pane's list — a dormant session has no door until it
launches and loses it when it exits, so the Attachments pane watches `SessionActivityDidChange`
and updates that one control rather than rebuilding itself several times a turn.

The terminal destination is an `AgentTerminalInputSurface`, not `TerminalSession` or its view
controller. The same two-operation capability carries cross-session prose delivery, while receipt,
boot and turn-in-flight policy remains in `SessionMessageDelivery` and `AgentRuntime`. This keeps
the two workflows on one live PTY without giving either Core policy presentation authority.

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
  the first), so `turnSpacing` is one `large` step rather than an additional 30-point gulf.
  Within a turn, the row kind, not one blanket gap, decides density — and it decides it for
  itself. Each kind declares a `Design.Chat.Rhythm`, the margins it wants above and below,
  beside its view in `ConversationRowView`; a surface declares the same for its own items; and
  the shared table composes two neighbours by collapsing their facing margins to the larger one.
  There is no list of pairs. The pairwise rule this replaced ("either neighbour is work: tight")
  put a user's bubble a turn's step under the heading above it and four points above the
  thinking beneath, because the bubble had no margin of its own for the rule to weigh.
  `ConversationRhythmTests` pins the tokens, the declarations and the gaps the table lays out.
- **Consecutive live tool calls reduce to one disclosure** as soon as the second arrives. A
  lone call remains readable, the group expands back to its canonical timeline rows, and the
  settled whole-turn fold still replaces it. This is the main transcript form of the work-group
  treatment already used in child transcripts and in t3code's `WorkGroupSection`.

**A settled turn folds behind one line** — "Worked for 42s" (`TurnFoldView`,
`Change.turnSettled`). This finishes what quieting the tool rows started: twenty quiet rows
are still twenty rows, and t3code's fold is the finished form — once a turn's terminal event
arrives, everything between its user message and its final assistant reply hides behind the
fold, so the conversation reads as its exchanges. The rules that came with it: an
*interrupted* turn stays expanded so the user keeps their place — the next turn folds it, and
it reads "Stopped after 42s" rather than claiming to have worked; the running turn never
folds. Folded work remains in the timeline but not in the live view hierarchy:
merely setting `isHidden` kept every nested tool and Markdown constraint in the window's layout
engine, so scrolling a settled conversation still laid out work that was not on screen.

The transcript is now a view-based `NSTableView`, not one retained `NSStackView` chain.
`ConversationTranscriptTable` owns the complete cheap ordering as stable timeline, divider, fold,
card and streaming identities; AppKit owns only reusable row hosts around the viewport. Timeline
rows build their Markdown/tool view when a host requests them and release it when that host is
recycled. Tool and long-user-message disclosure state lives in the table's sets, and turn
disclosure state in the controller's, rather than in a recyclable view, so returning to a row
restores what the user opened. Permission and changed-files cards are the small deliberate
exception: their live interaction state remains retained as a presentation item, but an
off-screen card is outside the attached constraint graph.

That table is one type for both transcripts. The mechanism — the ordering, the incremental
tool-run reduction, the identity index, the disclosure sets, the recycled host and its stated
column width, the spacing rule — was written twice, once here and once in the Subagents pane, and
the two had drifted: the child had a block-level Markdown split the parent lacked, the parent had
extension hosts and contextual actions the child could not reach, and a fold or spacing fix landed
in whichever file the reporter had open. `ConversationTranscriptTable` is generic over a
`ConversationTranscriptSurface`, which supplies the rows, the surface's own item kinds (here the
handoff banner, turn folds, retained cards and the streaming placeholder; in the child the
navigator, the heading and the missing-transcript notice) and a decorator that wraps a row in what
that pane adds. What a fold, a jump or a recycled host does is therefore decided in one place, and
a rendering improvement made in a row view or in the table reaches both panes.

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
host. AppKit alone owns measured row heights. The controller keeps only the last readable-width
scalar needed to invalidate those heights after wrapping changes; it does not mirror measured
identities or run a diagnostic callback on every row layout.

The extension composition seam is similarly pay-for-play. A user, assistant or tool row whose
customization resolution is empty keeps its native subtree directly instead of receiving a
container, composition host and observer that immediately return that same subtree. One controller
observer reloads the visible viewport only when an extension event changes whether a row needs a
wrapper; an already-customized wrapper handles content-only refresh itself. Permission cards remain
wrapped even when empty because they are rare retained interactions which must acquire late
customization without reconstructing or losing their decision authority.

Replay also has no table row to invalidate until its one final reload. A result arriving during
reduction therefore returns before any table-row lookup; searching the growing presentation for a
non-existent materialized row made generated 1,000-turn histories quadratic. Live timeline rows
resolve through the identity index, and the streaming placeholder resolves directly at the tail,
where it remains until the authoritative completed message replaces it. Those lookup rules
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
Rows are a pre-order value projection rendered by reusable cells in an embedded themed table.
That table owns no nested scroller: its logical height stays in the conversation document and
the conversation's clip bounds which cells exist, so folded descendants and offscreen files do
not leave retained AppKit trees behind. A disclosure rebuilds the projection and invalidates the
card's retained conversation-row height. Each directory row discloses its own subtree; the header
offers Collapse all and **View diff**, which opens Git Review on the Last Turn scope — and is
therefore withdrawn from a card the moment a newer turn is accepted, before its new baseline
replaces the old one.
Live turns only: a replayed turn's baseline is long gone, and diffing today's checkout
against it would attribute later work to an old exchange. An empty diff leaves no card.

**A file row previews its own diff under the pointer** (`ChangedFileDiffViewController`,
`HostPopoverID.conversationChangedFileDiff`). The reader already parsed the hunks to produce
the counts, so the preview costs no second git read — but the card is retained for as long as
the conversation, so what it keeps is bounded *at capture*: `ChangedFileDiffPreview.previews`
divides a `previewAggregateLineCap` across drawable files without letting any file exceed
`previewLineCap`, spends each share in hunk order, and counts what it could not cover. Short
files return unused budget to later files. The body is
`GitReviewDiffTextView` — one TextKit document per hunk, not a view per line — because the file
under the pointer is as likely to be a four-hundred-line rewrite as a two-line fix. The policy
is the disclosure's rather than the sidebar's: the surface scrolls, so it takes a grace to cross
the gap and holds itself open while the pointer rests on it (`HoverTrackingView` reports that
back). A directory, a binary file, and a card built without previews raise nothing, and the row
takes no tracking area in those cases — a hover wash on a row that answers nothing is the row
lying about itself.

**The tree's lead-in is one glyph column, not two.** Every row pays for the disclosure column
whether or not it draws a chevron, which is what puts a directory's files exactly one indent
step right of its own name. That rule was previously paid *twice* — a folder mark sat beside
every chevron — so each file row began 40 points inside the card before its name, plus a base
inset, and a two-level tree spent a fifth of a narrow pane on indentation alone. The folder
mark said what the chevron already said; it is gone, the base inset with it, and the step is
`Spacing.medium`. `ChangedFilesCardTests` asserts the parent/child relationship rather than the
absolute numbers, since the rule is what matters and the tokens may move.

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
`ThemedScrollView.onUserScroll` seam) and brackets gesture scrolls and scroller tracking with
live-scroll notifications, so our own `setBoundsOrigin` can never release the pin. A bounds
change within
`gestureAttribution` of the last gesture event re-derives the mode — near the bottom re-pins,
anywhere else frees — and momentum events keep refreshing the window, so a flick stays
attributed to its end. **Following intent does not give Threading ownership of the position while
AppKit is live-scrolling.** Streaming follow requests are reduced to one debt during the gesture,
momentum and elastic return; only `didEndLiveScrollNotification` plus a clip origin back inside its
constrained range releases the exact-bottom landing. Legacy wheel devices, which AppKit documents
as not necessarily receiving the notification pair, use the same short attribution window as
their end fallback. This preserves auto-follow without replacing the rubber band with a snap. A
minimap jump frees; a finished replay lands at the bottom and follows.
Whenever the viewport is away from the live end, the shared floating down-arrow is the explicit
way back: it lands on AppKit's constrained terminal offset and enters *following* again. Streaming
coalesces that control's visibility refresh with the existing follow pass, so a token does not
add another main-queue job or a walk over the transcript.

### iOS conversation boundary

The Mac-side remote mirror consumes `RemoteConversationSurface`, not
`ConversationViewController`. That MainActor capability exposes only the bounded provider-neutral
snapshot/row revision and the ordinary authorized prompt-submission path. The projection values
live in a Foundation-only Core contract; the AppKit controller is its adapter. `AgentRuntime`
returns the existential specifically to Core/Remote, so paging, resync, broadcasts, notification
suppression and prompt delivery cannot grow a dependency on the controller or its view hierarchy.
The mirror registry and runtime are still singleton-backed and remain active injection debt; this
edge removes presentation knowledge, not those globals.

Live plans cross that boundary as a revisioned summary and at most 64 exact steps per requested
page; stale pages cannot attach to a newer plan. The phone keeps the compact current-item strip
directly below its navigation bar and opens a transient anchored checklist backed by `LazyVStack`.
That disclosure is deliberately host-owned: a remote provider may supply only normalized step
titles and statuses, while Threading retains placement, paging, dismissal, theming, and the
authoritative turn-end clear.

The terminal half uses a separate `RemoteTerminalApplicationCapability`. WebSocket DTO handling,
authentication, share scope, session visibility, input-control policy, viewport bounds and replay
decisions remain in the transport. Only an admitted typed `SessionID` crosses into the capability,
which returns explicit available/unavailable or applied/unavailable outcomes for state, bounded
capture, input and viewport leases. Cheap state is separate from the screen repaint so keystrokes
and resize reconciliation do not walk the terminal grid. There is no durable terminal mutation in
this path: accepted raw input keeps its audit-before-PTY ordering, while atomic terminal-line
submission keeps its PTY-before-replay-receipt ordering. `AppEnvironment` builds the live
capability from its injected runtime and `AppDelegate` installs it before the listener starts;
Core/Remote never obtains an `AgentSessionViewController`, `TerminalSession`, or window.

A reconnect keeps the last complete terminal screen softened while replay and resize repair are
held behind the ordered `terminalReady` boundary. Crossing that boundary starts the reveal in the
same main-actor turn as buffered replay is delivered. SwiftTerm is live at that point, so the
departing blur is capped at 100 milliseconds—short enough to polish the handoff without making the
newly active screen look trapped underneath a lock whose correctness work is already finished.
Reduce Motion removes the transition entirely.

The iOS input surface follows the host's participant roster, not the mere presence of protocol
features. Input-control chrome and the atomic terminal-line composer appear only after another
reply-capable participant identity has accepted access; an unused invitation and another device
belonging to the same owner do not turn an owner-only terminal into collaboration UI. Owner-only
terminals therefore type directly into SwiftTerm's target TUI. During reconnect, before a capable
host has supplied its authoritative roster, and with an older host that cannot supply one, an
enabled independent-draft setting conservatively keeps the atomic composer until the client can
prove the session is owner-only. Accepted members who are away remain participants, so their
temporary absence does not change input mode or hide a device-local draft. A file chosen in
direct-input mode crosses a stricter seam than an ordinary key: after the Mac takes attachment
custody it uses the same shell-safe path spelling as a local terminal drop, leaves a trailing
separator for the next typed word, and sends the whole path list as one bracketed paste when the
live terminal mode requests it. It deliberately sends no Return. Both agent TUIs distinguish a
pasted image path from identical typed characters, so an accepted attachment insertion means the
paste semantic reached the PTY, not merely that some path bytes did.

The iOS conversation is a UIKit route, not a SwiftUI composition around a UIKit timeline.
`RemoteConversationViewController` owns the virtual collection, composer, command/skill results,
presence, input authority, submission receipts and keyboard constraint. It subscribes to the
connection, notification preferences and active host directly, coalescing changes onto one main
queue render. Draft and viewport continuity still use the host-and-session-scoped store; changing
the rendering owner did not change which client owns that working state.

The native text editor keeps one UIKit editing session while its availability is unchanged.
`textViewDidChange` still refreshes send state, persistence and completions after every edit, but
that render may not reapply `isEditable`: a held system Backspace is a sequence of native
`deleteBackward()` callbacks, and resetting the input contract after the first callback stops the
keyboard's repeat. Threading does not implement its own deletion timer or string indexing; UIKit
continues to own marked text and composed-character deletion.

Phone terminal keys and native-conversation buttons share one `MobileButtonFeedback`: a light
`UIImpactFeedbackGenerator` impact at intensity 0.85. The UIKit adapter prepares that one generator
on touch-down and fires only on the control's successful semantic activation—touch-up-inside for
ordinary controls and menu-presentation for a menu button—then prepares the next press. A drag-off,
cancellation or disabled control is silent. SwiftUI controls owned by the conversation call the
same feedback object from their successful button action; terminal modifier latches deliberately
keep `UISelectionFeedbackGenerator` because they confirm a state transition instead of a key
impact. The generator is process-wide rather than row-owned, so a transcript's cardinality cannot
create haptic engines or mount work. This interaction feedback remains host-owned: extensions may
supply normalized content for an existing button or row, but cannot add, replace or double its
confirmation.

The app and scene lifecycle are UIKit-owned so a native route can start without constructing a
root hosting graph. The dashboard and screens not yet migrated are intentionally contained in one
`UIHostingController`; the conversation stress route enters a native navigation controller
directly. A hosted `UIViewControllerRepresentable` remains the compatibility boundary when the
current SwiftUI dashboard navigates into a session. Rare modal work may still host SwiftUI—the
attention-recipient sheet does—but no hosting transaction participates in conversation cold open,
scrolling, typing or submission on the direct route.

An authoritative reconnect snapshot is not automatically a timeline reset. The mobile store first
reconciles ordered stable row identities: unchanged rows emit nothing, retained rows whose values
changed are reconfigured exactly, and metadata updates address only their synthetic cells. Only an
insert, removal or reorder takes the structural diffable path. That path preserves Markdown and
measured-height caches for unchanged ids, invalidates changed retained rows, and prunes disappeared
ids. Reverting to unconditional reset makes an unchanged 5,000-row reconnect a roughly half-second
animated rebuild; `ios-conversation-stress` rejects that behavior.

Remote tool calls are compact disclosures, not miniature transcript cards. Their collapsed header
is one horizontal 44-point target: tool identity, a single truncating subject, exceptional outcome
ink and a chevron. The result view is not materialized until expansion. This keeps a run of tools
scannable without shrinking the tap target, and keeps long output out of both the initial layout and
the ordinary reading path. Reconfiguration replaces the row's theme outline rather than layering a
new border and glow on every result, expansion or live palette update.

Do not anchor the cold composer to `UIKeyboardLayoutGuide`. On the measured simulator that caused
UIKit to load and initialize its text-input tracking coordinator while attaching the first window,
adding about 108 ms before paint. Keyboard frame notifications update the safe-area bottom
constraint instead; the keyboard demo verifies the same layout behavior when input is actually
requested.

## Queue, Steer, Stop

Three separate dispositions for a message typed while the agent is busy, and conflating any two
of them is the mistake every client makes first:

| | The running turn | The message |
|---|---|---|
| **Queue** | untouched | held here, sent as its own turn when the turn settles |
| **Steer** | continues, with the message appended at its next model boundary | joins the *running* turn — no new turn, no second terminal event |
| **Stop** | aborted at the next safe point | nothing |

Reordering and removal are operations on the **queue** only. A steered message is gone the moment
it is handed over, and there is nothing left to reorder.

The measurements behind all of it — Claude 2.1.223 and Codex 0.145.0, probed rather than read —
are in [the archived provider measurements](../archive/research/COMPOSER_QUEUE_FINDINGS.md).

### The transport boundary

Three optional protocols beside `ConversationStreamSession`
(`ConversationTurnControl.swift`), in the same style as `ModelSwitchableConversation`, because the
providers support different subsets and the difference is not a hierarchy:

| | Stop | Steer | Lifecycle |
|---|---|---|---|
| Claude `stream-json` | `control_request` `interrupt` | at the next model boundary | `command_lifecycle` keyed by our `uuid` |
| Codex app-server | `turn/interrupt` | `turn/steer` + `expectedTurnId` | `clientUserMessageId` |
| Grok / ACP | `session/cancel` | **none** | none |

`ConversationStreamSession` gains `canInterrupt`, `steerAvailability`, `interrupt`, `steer` and
`send(_:identifiedBy:)`, each of which casts once and answers honestly for a transport that
conforms to nothing. A fourth runtime therefore changes that one file and nothing in the view,
and a transport conforming to none still gets a working composer that queues locally.

**Steering is refused out loud rather than degraded.** `SteerAvailability` is `.available` or
`.unavailable(reason:)` — `.unsupported`, `.noActiveTurn`, `.turnKindRefusesSteering` — so ⌘Return
draws no promise Grok cannot keep. This is the "Chat… button that silently did nothing" failure,
already fixed once for terminal sessions.

### Threading owns the queue

`ConversationOutbox` is a pure value type on the view controller, even though Claude's CLI keeps a
command queue of its own and will drop an entry by uuid. Three reasons: reorder and edit need it
here (no provider queue can be reordered, and implementing a drag as cancel-and-resend races with
delivery on every gesture); Codex and ACP hold nothing between turns; and it has to cross
RemoteKit, which a queue living inside `ClaudeStreamSession` cannot. The provider's queue is the
*delivery* mechanism at flush time, and `MessageLifecycleReportingConversation` is the receipt.

Flushing takes **one item at a time, never concatenated** — two messages somebody wrote separately
are two turns — and goes through the same `GitTurnBaselineStore.prepareTurn` as a directly typed
message, or a queued turn shows the previous turn's diff as its own. The drain hangs off
`onSendAvailabilityChange` rather than a terminal event, because that is the one signal every
transport has for "the turn ended", however it ended.

### Stop stops the fleet

`interrupt()` on the parent alone leaves background subagents and shells running, and burning
tokens — which is exactly the situation Stop is reached for, so the parent-only version does least
where it matters most. Both implementations stop children first (Claude's `stop_task` per live
task id, Codex's `turn/interrupt` per child thread), best-effort and individually bounded, then
interrupt the parent unconditionally. Codex tracks child turns for *any* foreign conversation
rather than only registered ones: a child's `turn/started` can arrive before the activity
notification that registers it, and a Stop that depends on registration timing leaves it running.

**A stopped turn is not a failed turn**, and telling them apart needed a type. `StreamEvent`
carries `TurnOutcome` — `.completed`, `.failed`, `.stopped` — where it carried `isError: Bool`.
Every provider reports a user stop through its *error* channel (Claude `error_during_execution`,
Codex `TurnStatus.interrupted`, ACP `stopReason: "cancelled"`), so one flag made "you pressed
Stop" indistinguishable from "the model call failed": the fold read **You stopped after 42s** for
a network error, and the execution ledger's `interrupted` phase was unreachable. Each adapter
owns its own spelling-to-outcome mapping in its own file; the neutral type never learns a
provider's vocabulary.

Claude is the one case the wire cannot settle — `error_during_execution` covers genuine faults
too — so `ClaudeStreamSession.outcome(for:)` restates the parser's honest `.failed` as `.stopped`
only when it has an interrupt outstanding. The flag clears on the terminal event rather than on
the control response, which arrives ~10 ms earlier.

### What the composer promises

`PromptComposerMode` is `.ready` or `.working(canStop:canSteer:)` — one value the owner resolves
from the transport, so `PromptView` never asks who the provider is. Return queues, ⌘Return steers
where it can (the chord already means "the more committed of two affirmatives" here, from
`ContextCommentAlert`), and the send glyph becomes a Stop rather than a second button, because the
two are never both meaningful. Esc stops too, but only once the completion list has nothing nearer
to dismiss.

The queue rows sit **directly above the box, below the status line**. Both halves were arrived at
from a rendered fixture:

Only pending messages draw there. A handed-over message remains in `ConversationOutbox` for
lifecycle completion and interruption reclaim, but its user bubble is already the visible record;
showing the same prompt again in a disabled tray row was the gray duplicate above the composer.

- The status line is the *turn* talking — orb, working word, what the last one cost — and reads
  with the transcript. The queue is what happens next and belongs to the composer. Put above the
  status line, the queue sat across a sentence about the past.
- They are drawn as a **tray**: a quiet `Surface.panel` behind the rows. Without one the rows
  floated between two other things, and the space each stretched across to put its remove at the
  trailing edge belonged to nothing — a sentence left, a glyph right, a gap between them that
  read as a mistake. `panel` and not `field`, because the composer below is a field and two wells
  stacked read as two places to type.
- No position numbers: a queue's order is which row is above which, and a column of numbers
  beside sentences that already stack in order says one thing twice.
- The grip and the remove are **alpha, never `isHidden`**, and only inked on hover. A stack
  detaches a hidden arranged view, so geometry moved every time one appeared — the row without a
  grip started a glyph's width left of the others, and a remove materialising on hover shortened
  the sentence beside it as the pointer arrived.

Steered messages never appear there — they go straight into the transcript as a user bubble inside
the running turn, which is where they went.

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

**The cap is a ceiling, not a request.** `ConversationVirtualRowHost` lets the pane's own width
drive the row and states the column as the `lessThanOrEqualTo` it is; asking for 620 at a higher
priority than the pane looks equivalent and is not. A table cell is not pinned to its column —
under `usesAutomaticRowHeights` the table solves the cell's width from the constraints inside
it — so where the pane is narrower than the column the cell grows past the clip instead of
losing the argument. There is no horizontal scroller, so the words are just cut off mid-sentence
at the pane's edge. It showed first in the child transcript, which lives in the display pane and
is routinely half the column's width, and the same rows are correct in the conversation pane
only because it is usually wider than 644. Both widths are asserted in `ConversationRenderTests`:
nothing leaves a `DisplayPaneDefaults.defaultWidth` pane, and prose still reaches the full column
when the pane can hold it.

**"Centred" was a claim about a constraint, not about the app, for as long as that cell was free
to choose its own width.** The same sentence above — a cell is not pinned to its column — has a
second consequence that went unnoticed: a width nothing *determines* settles on the smallest that
satisfies the constraints, so the cell came out exactly 644pt wide and sat at the column's
leading edge. `centerXAnchor` then centred the content inside the cell rather than in the pane,
and the column the whole layout is designed around was flush against the sidebar in every window
wider than 644 — several hundred points of empty pane beside it, and the turn rail, which is
placed for a *centred* column, resting on the first character of every paragraph. The two faults
looked like one rail bug and were one layout bug.

`ConversationVirtualRowHost.setColumnWidth` states the width AppKit does not, pushed from
`viewDidLayout` for the cells already on screen and at `viewFor:row:` for the rest. It is what
makes `centerXAnchor` mean the pane's centre, and it closes the clipping fault above from the
other side as well: a cell pinned to its column can no longer grow past it. The priority is one
below required, so a row that genuinely cannot fit gives way in its own words rather than in an
unsatisfiable required set.

Because it was asserted on a fixture that centres a stack in a host by hand, the harness agreed
with itself throughout — the same "a component tested outside the container it ships in can pass
while being unusable" rule CLAUDE.md states, and here the container is the table.
`testTranscriptComposerAndRailStandOnOneCentredColumn` measures the live pane instead, held at a
stated width the way a split item holds it.

**The reply box stands on the column too** (`ConversationDefaults.composerWidth`). It used to
span the pane, which is how a single line of placeholder text came to be 1,400pt wide under a
620pt conversation. It is the readable measure plus the box's own padding, so the line being
typed lands on exactly the column the transcript is read on, and the status line above it is
inset from the *box* rather than from the pane for the same reason. Below that width the box
keeps the pane's inset and the row keeps the table's, which differ by a few points — a pane
narrower than the reading measure has no column for the two to share.

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

**Spacing has a floor, and past it the rail buckets** (`minimumMarkerSpacing`, `markCount`).
`railHeight` caps at `maximumHeightFraction` of the pane while spacing was that height divided by
the turns, so every exchange past about twenty-eight in a 900pt pane packed the marks tighter with
nothing to stop it: at two hundred turns they were under three points apart and `mark(atY:)` was
choosing between marks no pointer could separate. Past the floor the rail draws as many marks as it
can hold and each stands for the turn it is nearest — fewer marks than turns, which is a real loss
and the honest one, because the alternative is marks that cannot be hit. Everything the pointer
touches is in **mark** space; everything the preview and `onSelect` speak is in **turn** space;
`turnIndex(forMark:)` and `markIndex(forTurn:)` are the border, and below the threshold they are
the identity. A bucketed mark must still reach the conversation's first and last exchange and must
resolve in order, or a click lands somewhere the eye did not point.

**The taper follows the pointer, not the mark it is nearest.** The three width constants are one
profile (`markerWidthProfile`, `[24, 16, 10, 8]`) sampled at whole marks, and reading it by
*integer* distance is what made the rail step: the pointer crossed most of the gap between two
marks with the picture unchanged, then every mark in the taper took a new width in one frame. The
stops are the design and were never wrong; only the sampling was. `markerWidth(distance:)`
smoothsteps between them, `markerDistance` measures in **marks rather than points** so the taper
keeps its shape once the marks bunch, and `markerEmphasis` puts colour on the same curve — three
hard tone buckets under a smooth taper read as a rendering fault, widths flowing while tones
snapped on the same marks in the same frame. The taper itself ramps open and shut
(`advanceFisheye`, the `ThemedToggle` display-link pattern), and its centre outlives the pointer so
it settles back towards where the pointer left rather than collapsing flat.

**The rail indexes the conversation; the sticky header indexes the turn.** A turn that ran forty
tool calls is one mark by design, so inside it the rail has nothing to say and the reader scrolling
through it loses what every other line is about. `ConversationStickyStepView` pins the current
call's glyph, tool and `ToolCall.summary` to the top of the pane, and
`ConversationViewController.updateStickyStep` resolves it from the viewport's topmost row.

Two rules make it behave. **Chrome at the top means hide**: a divider, a fold, a card or the
streaming placeholder is a boundary that has already said where the reader is, and naming a step
over it would be a second, quieter answer to a question answered louder. And it **overlays rather
than insets** the scroll view, because insetting would move content under an anchored auto-scroll
and make arriving output jump by the header's height — the cost is that free scrolling can tuck a
line under it, which `landingClearance(for:)` pays back on the one path where it would actually
hurt, a deliberate jump landing its target underneath the strip that names it.

The model half is `ConversationTimeline.steps(inTurnStartingAt:)` and `currentStep(atOrBefore:)`.
Steps are recorded as calls append (`toolCallRowsByTurnStart`), keyed off `turnStartIndices.last`
rather than `currentTurnStartIndex` — a terminal event clears the latter, so a provider emitting one
more call after reporting the turn finished would contribute a step belonging to no turn. The
backward walk stops at the enclosing user message, so the top of a turn names *nothing* rather than
borrowing the previous exchange's last call.

Keyboard navigation is not optional here, because the rail is absent in a narrow pane and the
header only tells you where you are. ⌃⌘↑/↓ walk exchanges, the vertical siblings of Go Back and Go
Forward on the same ⌃⌘ window-structure layer; ⌥⌘↑/↓ walk steps, the way `⌃⌘B` refines to `⌥⌘B`.
Step navigation walks the **presentation** rather than the timeline, which is what makes a folded
turn's calls skip: they are not presented, so they are not places a reader can be sent. Turn
navigation walks `timeline.turns` regardless, which is also the escape hatch for a bucketed rail
whose marks no longer stand for every exchange.

That last one is why `ConversationMinimapMotionTests` exists and why it films rather than
photographs. **Every still of the stepped rail was correct**; only the sequence was wrong, so no
screenshot anyone would have taken could have caught it. The tests capture a pointer sweep frame by
frame and assert that consecutive frames differ, and they reproduce the old behaviour through the
real drawing code — a pointer that only ever reports the centre of the mark it is nearest *is*
sampling by nearest mark, with nothing stubbed to arrange it. Measured across 80pt of travel: the
old sampling produced four distinct frames, the new one produces one per position the pointer was
actually at. The fixture calls the view's drawing boundary into its own bitmap context; an unshown
layer's display cache stopped refreshing reliably on macOS 26, and filming that cache tests window
visibility rather than taper motion. The ramp is driven by phase at the interpolation boundary for
the same reason: wall-clock scheduling is the display link's concern, not the curve's.

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

The test target is a filesystem-synchronized Xcode group. A new Swift file below
`Tests/ThreadingTests` is compiled automatically, with no per-file project registration.

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

**Model then mode then effort then speed leads the row**, matching the opening composer wherever
the selected model publishes those controls. The mode chip
is also configured *before* the model-catalog guard: a runtime that publishes no catalog — Grok
today — still has a permission posture, and the early return that hides the model, effort and
speed chips used to take this one with it.

**Speed has one presentation on both composers.** `ConversationSpeedPresentation` owns the
**Follow General Setting**, **Standard**, and **Fast** rows, including their selected state and the
chip's resolved title. It owns the chip's *mark* too, from the same resolution: `chip(…)` returns
the symbol beside the words, because the bolt is one of the values rather than the name of the
control. Both composers drew `bolt.fill` whatever the chip said, so "Standard" arrived under the
mark that means Fast — and under the mark the status card shows only while fast mode is on. Fast
keeps the bolt; Standard and Agent's Setting take `gauge`. Native stores the same optional `AgentSession.fastMode` the opening draft
hands to session creation. Claude applies a resolved Standard/Fast choice over its live control
channel; Codex reads it into the next `turn/start`. Following a General setting of Agent's Setting
cannot reconstruct the provider's original value in a running process, so that case records the
inheritance for restart and prints a muted notice instead of claiming a live change.

**What choosing a mode does differs by provider, and the menu says which.**
`PermissionModePresentation` is the one place the rows, the inherit wording and the `hand.raised`
symbol are written down; the session row's menu, the opening composer's chip and this chip all
build from it, so three entrances to one setting cannot name the app-wide default three ways.
It also owns the one provider-specific title: Codex renders Auto as **Auto (Approve for me)**,
because that choice states `approvals_reviewer = "auto_review"` and must not look like Codex's
ordinary human-reviewed Auto preset.
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
- **Codex records for the next launch.** Its posture is stated in the `--ask-for-approval`,
  `--sandbox`, and one-run `approvals_reviewer` configuration of the `codex app-server` process,
  and `turn/start` carries only
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
wrapping and selection come free. Assistant-authored link targets are actions only for `http` and
`https`: every other URL scheme keeps its visible label but receives neither AppKit's live-link
attribute nor link styling, so agent prose cannot hand `file:` or a custom-app URL to the system.
Inline `*` and `_` runs follow CommonMark's left/right-flanking rules: arithmetic and intraword
identifiers remain literal, while `_emphasis_` and `**strong**` still style. Emphasis containers
re-scan their content and merge their font trait into nested links, code spans and opposite
emphasis, rather than printing the child's syntax as styled prose. That recursion stops at
`MarkdownDefaults.maximumInlineNestingDepth`; provider-authored content beyond the ceiling remains
literal so one pathological line cannot grow the display stack or repeated grapheme allocations
without bound. Provider reasoning is still a distinct thinking row, but it passes through this
same bounded renderer with `MarkdownStyle.thinking`: Markdown structure is honoured while every
ink tier remains tertiary, so a provider's `**summary**` reads as quiet emphasis rather than raw
punctuation or answer-strength prose.

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
full-width semantic wash per line (the width is what reads as a diff, so it is rows, not an
attributed string) with a `+`/`−` gutter. Changed code uses neutral label ink measured against
that wash rather than repeating the change in low-contrast red or green; this is intentionally
theme-derived rather than hard-coded white, because a light theme needs dark ink for the same
result. Long lines wrap because the pane is narrow and hiding half a change off the right edge
is worse. The same `DiffView` is the approval sheet's
accessory: an edit is approved on *what* it changes, which the sheet now shows, not merely which
file. This is opencode's diff-viewer idea in AppKit and theme semantic colours.

`JSONLReader` and `ClaudeTranscript` were extracted rather than copied: `SessionImporter`
already read these files, and the transcript path was already derived in two places. The
reader's correctness notes — never cap a record, let the caller decide when to stop — now live
in one place instead of being rediscovered per caller.

## Workspace-file mentions are references, not pasted files

The composer recognizes a whitespace-delimited `@` token after the existing leading `/` command
and `$` skill parsers have had their chance. An `@` inside a word remains text, so email addresses
and ordinary prose are not captured. Choosing a row replaces only that token and stages a
`ConversationContextAttachment` whose source is `workspaceFile` and whose locator is a
project-relative path. It has no eager excerpt: file bytes do not enter editable prose or the
completion model.

The reference uses the existing context envelope through local continuity storage, scheduled and
queued prompts, provider transcript replay, and `RemoteConversationContextAttachmentDTO`. Before
submit or steer, the conversation host refreshes the Git-visible roster and verifies that every
saved path is still a contained regular file. A missing, renamed, deleted, ignored, or escaping
symlink is reported as stale and the draft remains staged; silently sending an unresolved
reference would turn structured context into a false promise.
