# The Session Control Plane

Typed, scoped operations over sessions — who may see which sessions and send what to whom —
with the rules in one place for every caller.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

## Where this came from, and where it goes

The trigger was a review of [get-bb/bb](https://github.com/get-bb/bb) (2026-08-06), whose most
consequential property is that its app, CLI, HTTP API and SDK are equal interfaces over one
system: every action an interface can take is a programmable operation with an identity behind
it. Threading's conclusion from that review was not to copy bb's architecture — Threading stays
the native, supervised control room — but to make the control room programmable, one typed
contract at a time: **operations × scope × authority**, with the UI, MCP, a future CLI and
remote clients as adapters over the same contract.

The agreed sequencing, so later slices land in order:

1. Typed operations, scope, refusals — `ControlContract.swift` (**this slice**, with MCP as
   the first adapter: `list_sessions`, `send_to_session`).
2. Richer actor identity and grants — per-session/per-extension authority beyond the default
   project scope, and a durable audit of who controlled whom, through which grant, and why.
3. Queue/steer/wait as first-class operations — **done**: `queue` and `steer` dispositions on
   `send_to_session`, and `watch_session` as the wait boundary, built on the
   `SessionActivityDidChange` edge with `SessionArchiveScheduler` as the shape copied. A
   completed notice therefore reaches a parent on request; sending one *unasked* waits for the
   supervision record in slice four.
4. A project "manager" as a **role, not a session type**: an ordinary session granted
   `project` scope, dogfooded over this contract. Manager state lives in a durable supervision
   record owned by the plane, never only in the manager's own transcript.
5. Environments as first-class records (managed worktrees with provenance and cleanup rules),
   then remote hosts — only after the contract above is stable.

What we deliberately did not copy from bb: full-trust in-process plugins (Threading's safe
extensions stay out-of-process and capability-gated), automatic `git worktree remove --force`
cleanup, and a publicly reachable HTTP server as the first interface.

## The contract

`ControlContract.swift` states three independent axes, none inferable from another:

- **`ControlActor`** — who is asking. For an agent session the id comes from the MCP URL token
  (`MCPSessionRegistry`), never from an argument, so a caller cannot claim to be a session it
  is not. Future cases: the user's own UI, an extension identity, a CLI, a remote device.
- **`ControlScope`** — what the actor may see and touch. Slice one grants exactly
  `.project(theCallersOwn)`. Broader grants are new enum cases with their own membership
  rules, not loosened checks.
- **Typed outcomes** — `ControlSessionOverview`, `ControlSendOutcome`, `ControlRefusal`.
  Refusals are values; prose belongs to adapters.

`WorkspaceControlPlane` resolves them. It is the **only** place scope is enforced, so a rule
can never be looser for one caller than another. Dependencies are injected closures in
`SessionArchiveScheduler`'s style — `WorkspaceControlPlaneTests` drives the plane with fakes
and no live agent — and the live set is assembled once, on `AgentToolDependencies`, which is
also what keeps handlers out of the singleton business (`check_architecture_boundaries.sh`
enforces that).

Two refusal decisions worth their words:

- **Out of scope answers exactly like nonexistent** (`.targetUnknown` for both). Telling them
  apart would let a caller probe the workspace it was not granted.
- **A busy terminal refuses rather than delivers** (`.targetBusy`). Text typed into a working
  TUI lands inside whatever is on screen — a permission prompt, a half-typed composer line —
  the same rule `SessionCoordinator.canAskAgentToRename` applies to the rename request.

## Delivery is per surface, and the outcome is the surface's own answer

`SessionMessageDelivery` (Core/Agent) is `SessionContextHandoff`'s sibling for prose: one seam
answers for whatever surface a session is on, resolved per call. Its rules are a pure function
over injected facts (`deliver(_:chat:terminal:)`, held by `SessionMessageDeliveryTests`); the
live wrapper only gathers the facts. Terminal writes cross `AgentTerminalInputSurface`, whose
running-only runtime query returns paste/submit operations without a terminal emulator or UI
controller. The dependency gate rejects reintroducing the old inferred controller lookup anywhere
in Core.

| Target surface | Delivery | Outcome |
|---|---|---|
| Native chat, ready | `acceptAppMessage` → visible queue, flushed toward the next turn | `.sentNow` |
| Native chat, mid-turn or queue occupied | `acceptAppMessage` → parked in the visible queue | `.queuedBehindTurn` |
| Terminal, idle **and boot-verified** | `pasteText`, the Return in its own write a beat later — then **wait for the receipt**: the session's own turn-started report, within `SessionMessageDeliveryDefaults.terminalReceiptTimeout` | `.sentNow` only on the receipt |
| Terminal, typed but never confirmed | the text may sit unsent or have been discarded by a repaint the tracker cannot see | `.typedUnconfirmed` |
| Terminal, mid-turn or still booting | refused | `.busyTerminal` |
| Dormant — including a kept conversation whose agent exited | refused; resuming is the user's decision | `.noLiveSurface` |

The receipt (`AgentRuntime.awaitReportedTurnStart`) resolves only on *reported* turns, never
the output heuristic — inferred turns are precisely what a compaction repaint fakes. It was
bought by the second live delivery ever made: typed into a session mid-`/compact` — a turn
that reports no hooks and paints almost nothing, so the tracker honestly said idle — and
discarded by the redraw while the tool answered "typed and submitted". "We pressed Return" is
a fact about our keystrokes; only the target's own report proves arrival.

Two rules here were bought with review findings rather than foresight, and both are the same
lesson — **never infer an outcome from beside the surface**:

- A conversation that *exists* is not one that is *running*: `AgentRuntime` keeps the
  `ConversationViewController` after its agent exits, and an existence check reported
  `.sentNow` for text whose only home was an in-memory queue a later resume discards.
- Sent-versus-queued was first inferred from `activity.hasTurnInFlight` read beside the send —
  wrong in both directions (`submit` answers true for send *and* enqueue; a settled turn still
  reads `.working` while background work finishes). `AppMessageAcceptance` is the conversation
  reporting what it did, and because acceptance goes **through the outbox**, a transport that
  refuses after the settle reclaims the message into the visible rail instead of destroying
  text no composer holds.
- A terminal's `isRunning` flips at PTY spawn, seconds before the CLI's composer exists —
  typed text landed in a login shell. For runtimes with a bridge (`.terminalThreadingBridge`),
  delivery waits until the process has been **heard from** (`hasHeardFromProcess`: its
  SessionStart hook, or any later report); a runtime that cannot verify is taken at
  `isMidTurn`'s word rather than refused forever. The first live dogfood found the stricter
  fact (`reportsOwnTurns`, which latches only on *turn* reports) refusing every session idle
  since an app relaunch — listed as idle, refused as still-booting — because SessionStart was
  the one report nothing latched.

Everything about a delivery is visible: it is echoed into the target transcript as a user
turn, queues in the rail the user can edit, and spends the target's usage openly. An invisible
delivery channel would be the "instruction sent to an agent invisibly" failure `sessions.md`
already names for the rename request.

## Provenance is part of the message

Every delivery is prefixed by the plane (never by the calling agent) with a header naming the
sending session's title and lowercased Threading id, and stating that it was sent by that
session's agent, not typed by the user. The mechanics of arrival are a user turn — that is
honest, since it runs as one — so the header is what keeps the receiving agent, and the user
reading over its shoulder, from mistaking a peer's words for the user's own. The group
instruction tells agents to weigh such messages as a collaborator's report, and never to relay
one mechanically — the ping-pong loop is the obvious failure mode, and the visible queue plus
`ConversationOutboxDefaults.maximumItems` bound it while a rate rule waits for slice two.

The header is the only part of a delivery Threading vouches for, and only as the **first
line**: the body is the sender's words, unescaped, so a sender can write a header-shaped line
of its own further down, or claim "the user then said …". The group instruction tells
receivers exactly that — one header, first line, everything else is the sender. The title slot
inside the header is fenced (`safeHeaderTitle`: `[`, `]`, `“`, `”`, newlines → `'`), because a
session names itself and a title ending in `”` or `]` closed the frame early. Messages are
also stripped of control characters before delivery (`sanitized`): on the terminal path ESC
and C0/C1 bytes are live keystrokes, and `ESC [201~` inside a body would end the bracketed
paste and hand the rest — Returns, Ctrl-C — to the TUI as typing.

Auditing costs nothing here: every `tools/call` is already recorded both ways into the
hash-linked execution ledger at the `MCPServer` choke point ([`execution-audit.md`](execution-audit.md)),
so cross-session sends arrive attributed — caller from the URL token, arguments and outcome
exact.

## The MCP adapter

Two tools in one new catalog group (`workspace-control`, family `.workspace`, title "Other
sessions" — the deliberate sibling of "This session"): `list_sessions` and `send_to_session`.
The group follows the catalog's standing policy — absent from the disabled set means enabled —
and the Tools page switch is the off switch; what made "on by default" defensible is that
every consequence is visible (transcript echo, queue rail, receipt in the ledger) and scoped
to one project. `send_to_session` addresses targets by **Threading id** only — the id every
app-side surface keys on — never a provider transcript id, which lives in a different identity
space and is absent for half the runtimes.

This closes the gap [`sessions.md`](sessions.md) records under side chats, from both ends: a
fork can send its conclusion back to its parent (`list_sessions` names the parent beside
"side chat of"), and the row's **Send Result to Parent** action lets the user ask for exactly
that — one line into the side chat naming `send_to_session` and the parent's id, the rename
request's pattern (`SessionReportBackRequest`, gated by `SessionCoordinator.canAskForReportBack`
so the offer only exists where the delivery would land).

## Steer, as a disposition rather than a tool

`send_to_session` takes `disposition: "steer"` to add a message to the turn a chat target is
already running — `ConversationOutboxCoordination.steer`'s control-plane twin, minus the two
things that belong to the composer alone: it never clears anyone's prompt box, and it never
falls back to the queue. The composer's fallback is right for a person whose keystroke raced
the settle; a caller who *asked* to steer is told the transport's own answer
(`SteerRefusal`: unsupported / no active turn / a review or compaction refusing additions)
and decides for itself — the "silently degraded to something else" failure this repository
keeps re-fixing, refused at the contract level this time. Steering is a stream operation, so
a terminal or dormant target refuses with `steerNeedsLiveChat` whatever its activity says.
The tool description and group instruction both carry the measured caveat from
[the archived provider measurements](../archive/research/COMPOSER_QUEUE_FINDINGS.md) §2.4: steered text lands beside
tool results, where models discard override-shaped instructions as injection — steer to add,
never to countermand.

## Watch, as one notice instead of polling

`watch_session` arms a one-shot notice: when the named sibling next **settles**, Threading
delivers a message saying so to the session that asked. Without it, a session waiting on a
sibling's result can only call `list_sessions` again and again — each call spending a turn of
its own usage to learn nothing, and the polling interval deciding how late the answer arrives.

**The boundary is the one the app already has.** `SessionWatchCenter` (Core/Control) watches the
same `SessionActivityDidChange` edge out of `hasTurnInFlight` that `SessionArchiveScheduler`
fires on — the agent's own turn report where a runtime gives one, the output heuristic where it
does not — plus the two endings that are not a finished turn and are just as final for someone
waiting on one: `.dormant` (the agent exited) and `.limitReached` (nothing runs there until the
window resets). A watch that ignored those would leave an agent waiting on a session that will
never speak again, which is the failure the tool exists to prevent.

**One-shot, in memory, bounded.** The watch is spent when it fires; re-arming is another call, and
it lives only with the app run. With no `timeout_minutes`, the watch has no wall-clock expiry: it
names the target's current turn, so an arbitrary default deadline would replace the event the
caller asked for with a clock it did not ask for. A caller that needs a deadline supplies a
positive finite number of minutes; that watch expires **with a notice saying so**. One session
may hold at most `ControlWatchDefaults.maximumPerWatcher` (8), which bounds both memory and being
woken because every delivered notice spends a turn of the watcher's own usage.

**An already-settled target is refused, not watched** (`.targetAlreadySettled`, which is an
outcome rather than a `ControlRefusal` — nothing was wrong with the ask). There is no edge left to
wait for, and a watch armed on an idle session would fire on whatever it is next asked to do,
which is not the work the caller was waiting on. The answer says to read `list_sessions` instead.

**The notice is Threading speaking, and says so.** It carries its own frame —
`[Session watch — Threading] “<title>” (<id>) …` — and deliberately **not** the
`[Cross-session message …]` header, which states that the body was written by the named session's
agent. Nothing in a watch notice was: the target never asked for it and need not know a watch
existed, so reusing that header would be a false claim about who is speaking. The title is read
at fire time (a session renames itself mid-turn) and fenced through `safeHeaderTitle`, since a
title ending in `”` or `]` would close Threading's frame early.

Delivery rides the same receipt-backed seam a send does (`SessionMessageDelivery.deliver` with a
completion), so an undeliverable notice is *known* to be undeliverable: `.noLiveSurface`,
`.busyTerminal`, `.typedUnconfirmed` and `.notTaken` each leave one `EventLog` entry naming
watcher and target. The watch is spent either way — that entry is the only record that the agent
waiting on it was never told.

Scope is the plane's, not the tool's: `WorkspaceControlPlane.watch` runs the same caller,
self-target, membership and archived guards a send runs, minus the ones about a message, so a
watch reaches exactly as far as a message does.

## Handing an agent a session: the dragged row

The user's side of the plane. The habit it replaces was **Copy ▸ Agent Session ID** followed
by a sentence typed into another session's input saying what the id was and what to do with it
— which id goes to which tool is exactly the thing a person gets wrong, since the runtime's own
id and the Threading id are the same string for Claude and Grok and different for Codex and
OpenCode. So a session row now **drags out of the sidebar** as a reference
(`ProjectSidebarDragDrop.pasteboardWriterForItem`, one private pasteboard type
`SessionReferencePasteboard.type` and no `.string` beside it — a plain-text flavour would make
every text field in the app a destination for a paragraph of tool names), and the drop site
turns it into the words for its surface.

`SessionReference` (Core/Agent) is the **name card**: title (fenced with `safeHeaderTitle`, since
a session names itself and `]` would close the terminal frame early), runtime, project name and
execution path, the runtime's own id and its transcript path. Deliberately not the live state —
a reference sits in a composer while the person keeps typing, and `working`/`idle` are
`list_sessions`' to report when asked. Resolved at the drop, not the drag (`SessionReference.live`),
so a row renamed mid-gesture lands under its new name.

`SessionReferenceReader` is **who is reading**, reduced to what changes the words: the receiver's
project (scope is per project, and out-of-scope answers as nonexistent, so a row from another
project is told "cannot reach it from here" rather than handed a call that will be refused);
whether its *surface* receives the bridge (`.terminalThreadingBridge` for a terminal drop,
`.threadingBridge` for a composer drop — an OpenCode TUI has no tools and is told so) and the
"Other sessions" group is on; and whether the row is the receiver itself ("it is you"). The
drop site names the surface, because a session's stored preference and the surface in front of
the user can differ.

`SessionReferenceBrief` is **the words**, three sentences in a fixed order — what it is, how to
reach it, what it is called elsewhere — and one text for both surfaces:

- a terminal is pasted `terminalText`: one bracketed line, `[Threading session “…” — Claude
  Code, Threading id …, in this project. Reach it with the Threading MCP tools: … ] `, through
  `pasteText` so it arrives as one unit rather than as keystrokes. Bracketed because a TUI's
  composer has no sidecar — the frame is what separates the reference from the sentence typed
  after it, the same convention as the CLIs' own `[Image #1]` and `[Pasted text]` tokens; one
  line because a multi-line paste is folded into a placeholder the person can no longer read.
  A shell drawer refuses the drop (`dropReader == .shell`): a shell has no agent to brief, and
  pasting "whichever id" would bring back the ambiguity the Copy submenu retired.
- a native composer stages `contextAttachment`: a `ConversationContextAttachment` whose source
  is `.session`, `locator` the Threading id and `excerpt` the brief — so it rides the existing
  receipt chip, draft, queue, scheduled turn, transport envelope and replay with no second
  shape. The rail draws it as its own chip under the row's title rather than folding it into
  "1 reference", because it is the one named thing the person just dropped.
  `presentationDetail` shows the id, not the brief: the sentences are for the agent.

The third sentence always closes with the runtime's own id and transcript marked as *not*
Threading ids — the whole reason a hand-typed version of this went wrong.

## What slice one deliberately does not do

- **No auto-resume of dormant targets.** Booting an agent process is the user's decision;
  the scheduled-messages feature departs from this deliberately for its own actor — the user,
  in advance and in writing — and documents where it still refuses.
- **No reply channel.** A send is fire-and-forget; the receiving session answers into its own
  conversation. Report-back is another `send_to_session` in the other direction.
- **No cross-project scope, no workspace scope, no grants UI.** The enum has one case on
  purpose; slice two adds identity and grants before anything broadens.

## Known boundaries, named rather than implied

- **A queued delivery is as durable as the process holding it.** `ConversationOutbox` is
  in-memory; a target that exits before its turn settles takes the queue with it, and the
  sender learned that from the outcome wording, not from a receipt. Durable scheduled sends
  are separate, in-flight work built beside this plane — its refusal semantics
  (`.noLiveSurface` over a false `.sentNow`) are what that work stands on.
- **Provenance authenticates the header, not the body.** A sender can still *say* anything,
  including imitating the header or quoting an invented user. A structured provenance channel
  — the message as data, rendered by the receiver's own UI with an origin chip — is slice-two
  work; until then the one-header rule in the group instruction is the boundary.

## Frontend-neutral interactive host operations

The command palette and workspace-file mention search follow the same boundary rule as workspace
control: a frontend receives semantic values and invokes a host operation; it does not inherit
the objects the Mac adapter uses to draw or collect input.

`HostCommandPlane` enumerates `HostCommandDescriptor` values carrying the existing stable command
id, localized title/detail/group, resolved shortcut, origin, scope, risk and explicit
availability. `AppCommand.hostDescriptor` is the one projection, and `AppDelegate` is the one
invoker. Menu selectors, shortcuts and the palette all return to that invoker rather than
implementing commands beside it. Invocation enumerates again before dispatch, so a changed
selection, missing surface, or disabled extension becomes an honest refusal with its current
reason. `CommandRegistryDidChange` causes an open palette to discard removed extension rows.

`WorkspaceFileSearchPlane` accepts a session id plus query and returns only bounded
`WorkspaceFileReference` values. The Mac root resolver uses
`ProjectStore.executionProject(forSessionID:)`, so a managed session resolves to its execution
worktree while retaining its logical project identity. No operation returning arbitrary bytes or
an absolute URL is part of this contract. A future remote adapter may transport the structured
relative reference, but it does not thereby acquire a filesystem browser.
