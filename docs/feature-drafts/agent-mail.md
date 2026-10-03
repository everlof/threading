# Agent mail: durable, cross-host messages between agents

> Status: **in progress** (2026-10-03). The controller half — mailboxes, grants, notices, ask,
> wake and the SSH transport — is implemented and recorded in
> [`autonomous-controller.md`](../architecture/autonomous-controller.md#agent-mail-schema-v7).
> The Mac half — session mailboxes (`MacMailbox`), the four Mac MCP tools, `send_to_session`
> storing undeliverable messages as mail, Claude/Codex answering hooks, native-chat and boundary
> notices, sync with remote hosts' controllers over owner SSH, remote-host sessions keeping their
> mailbox on the host (`RemoteSessionMailboxes`), owner grants and contacts in the session Info
> panel, and `wake` for dormant Mac chats — is implemented (2026-10-03) and recorded in
> [`control-plane.md`](../architecture/control-plane.md#agent-mail-on-the-mac). Not yet: `ask`
> for Mac sessions, chain budgets measured against Mac transcript usage, and forwarding a
> session's mail when its project moves to another host. Supersedes the worker-only
> `agent-messaging.md` draft (2026-10-02), whose grant modes, chain bounds and Rindabox notes are
> folded in below. Extends [`control-plane.md`](../architecture/control-plane.md) (interactive
> sessions), [`autonomous-controller.md`](../architecture/autonomous-controller.md) (workers) and
> [`remote-execution-hosts.md`](remote-execution-hosts.md) (SSH to Linux hosts). Not
> Rindabox-specific: Rindabox is one consumer. Companions:
> [`portable-trigger-sources.md`](portable-trigger-sources.md) (waking on mail is a trigger
> there) and [`agent-usage-ledger.md`](agent-usage-ledger.md) (the spend that admission reads).

## The problem

Two things an agent cannot do today:

1. **Reach an agent on another host.** `send_to_session` reaches Mac sessions, and a remote-host
   Claude can call it only because the reverse tunnel makes it a Mac session
   (`MCPRemoteSessionToolScope`). Controller workers on a VPS have no sending tool at all — the
   only messages are person-authored `work-message` follow-ups on one task — and nothing carries a
   message from a VPS to the Mac or from one VPS to another. Neither store has a host identity.
2. **Reach an agent that is busy or not running.** Delivery is *into a live surface* or nothing:
   `SessionMessageDelivery` answers `.busyTerminal` for a working terminal and `.noLiveSurface`
   for a dormant session, and `send_to_session` maps both to a refusal with no retry. The native
   chat queue (`ConversationOutbox`) is in-memory and discarded on resume. Every lifecycle hook is
   deliberately silent (`session-activity.md`), so nothing reaches a terminal agent mid-turn.

What exists to build on: per-session MCP tokens that already work across the SSH reverse tunnel;
native-chat steer (Claude stream-json, Codex app-server); `ScheduledMessageStore`, a durable
per-session queue that already retries on settle and wakes dormant native sessions; the
controller's typed-record SQLite store with idempotent caller-minted IDs, a per-task
consumed-acknowledgement and a finish-transaction check; and `owner-rpc`, an SSH forced-command
transport with no listener.

### Rejected: keep a terminal open per agent and type into it

A typed message lives only in that process (crash, deploy, reboot or account failover loses it,
and nothing records whether it was read); "done" would have to be scraped from rendered output,
which the controller deliberately never interprets; an idle terminal per agent holds a provider
session and usage window open around the clock; and a busy one cannot accept input without
landing inside whatever is on screen. The terminal stays a debugging surface.

### Rejected: one hub host holding every mailbox

Simpler to inspect, but the hub being unreachable stops all cross-host mail, and the Mac — the
host most often offline — could never be the hub. Chosen instead: **every host keeps its own
mailbox and forwards over SSH** (below). A deployment may still *configure* one VPS as everyone's
only peer; that is a topology, not a protocol.

## Contract

1. **Sending is storing.** `send_message` succeeds when the message is durably accepted into the
   sender host's outbox (same host: straight into the recipient's inbox). Whether the recipient is
   running, busy, dormant or on another host changes *when* it is delivered, never *whether* the
   send is refused. Refusals are reserved for authority (no grant), bounds (quota, depth, size)
   and unknown addresses.
2. **A message is addressed to a mailbox, not a process.** Addresses are
   `<host>/session/<threading-id>` and `<host>/worker/<worker-uuid>`. A host mints a stable host
   UUID and a display name once; it never changes with hostname or IP. `person:`/`group:`
   recipients are a later slice (they already exist as question recipients in the controller).
   **A mailbox lives on the host that runs its agent's process**, and the address's host part is
   that host (see [Mailbox location](#mailbox-location)).
3. **The sender is authenticated, never claimed.** On the Mac from the MCP URL token
   (`MCPSessionRegistry`); in `agent-mcp` from the execution credential, resolved to its
   worker; between hosts from the SSH peer key. A peer may only vouch for senders on its own host
   (`message.sender.host == authenticatedPeer.host`). No relaying in v1.
4. **Delivery is a separate, per-surface step on the recipient's host** (table below), and its
   outcome is that surface's own answer — the control-plane rule that a delivery is proved by the
   target's report, never inferred from beside it.
5. **A busy agent gets a notice, not the body.** Mid-turn, the host injects a one-line,
   host-authored notice ("2 unread messages from *deploy-bot* on *vps-1* — read with `inbox`").
   The body is read through the `inbox` tool, inside the existing provenance framing (one
   vouched header line, the sender's words below it, control characters stripped). A peer's text
   therefore never arrives as harness context. Chosen over injecting the body: it costs one tool
   call and keeps the "only the first line is vouched for" rule intact.
6. **Read is not acknowledged.** The recipient acknowledges each message it acted on (`ack`),
   as with `work_message_consumed`. Unacknowledged `interrupt` messages block a controller
   execution's `work_finish` in the same transaction.
7. **A message carries information, never authority.** It cannot grant tools, change a recipe,
   pick a destination, answer a person's question, widen a grant or confer manager scope.
8. **Loops are bounded mechanically.** Every message carries a chain ID and depth; a reply or a
   message sent by work a message woke is one deeper; sends past depth 4 are refused; a `wake`
   never targets a mailbox already in the chain unless answering its `ask`. Spend is bounded where
   it happens — at admission — and message counts only as a loop fuse (see [Bounds](#bounds)).
9. **Everything is visible.** The Mac shows each session's inbox/outbox; a delivered message is
   echoed into the target's transcript as today; the controller's task history shows messages
   beside checkpoints; every send and receipt is in the execution ledger and event journal.

## Mailbox location

Decided 2026-10-03: **each computer keeps its agents' input and output on that computer.** A Mac
session's mailbox is on the Mac; a controller worker's is on its host; a remote-host session's is
on the Linux host it runs on, even though its record, token and transcript index are on the Mac.

Why, rather than keeping every session's mailbox on the Mac that owns its record:

- **Mail does not depend on the Mac being reachable.** A remote-host session reaches Threading's
  tools only through the Mac's reverse tunnel today. With its mailbox on the Mac, a worker on the
  same VPS writing to it would wait for the laptop to come back.
- **The busy-agent notice stays local.** The answering hook runs on every tool call; it must be an
  indexed local query, never a network round trip with a timeout on the hot path.
- **One routing rule.** An address's host is where the process runs, so sync never resolves where
  a session "really" lives.

What it costs, and how each is paid:

- **Tools.** A remote-host session gets the mail tools from a host-local MCP server
  (`threading-controller agent-mcp` in mailbox mode) beside the Mac's bridged one. The Mac mints
  its mailbox credential at launch and writes it with the other `0600` launch files, as the
  controller does for an execution credential. The Mac's bridged server does not also offer mail
  tools to that session, so there is one answer per tool.
- **The Mac's view.** The Mac reads a remote-host session's inbox and outbox over its existing
  owner SSH connection and shows them as stale, with their age, while the host is unreachable
  ([`status-integrity.md`](../architecture/status-integrity.md)). It never keeps a second copy
  that could disagree.
- **Moving a session.** When a project's execution host changes, its sessions' addresses change.
  The old host keeps a forwarding record (old address → new address, owner-written, revisioned)
  and moves unacknowledged mail with the session at the hand-over; a message arriving at the old
  address afterwards is forwarded once, not relayed onward again.
- **Wake still needs the Mac.** The Mac is the authority that launches a remote-host session, so
  a `wake` for a dormant one waits until the Mac can reach the host. Mail is never lost meanwhile;
  `directory` reports the recipient as "wakes when its Mac is connected".

## Grants

`grant` records on the **recipient's** host: sender pattern (an address, `<host>/*`, or
`<host>/project/<id>/*`) → recipient, a mode, and a compare-and-swap revision. Owner-authored
only — no tool lets an agent write one. Rechecked in the same transaction as acceptance, so a
revocation applies to the next send.

| Mode | Effect |
|---|---|
| `notify` | Delivered when the recipient is next live, at its next boundary. |
| `wake` | Also starts an idle recipient. **Not a separate mechanism:** mail arriving is a built-in source in [`portable-trigger-sources.md`](portable-trigger-sources.md), and `wake` is a trigger on it (sender pattern → recipient), with ordinary matching, admission, spend checks and history. A dormant session is resumed (native only, as scheduled messages do); a worker gets one coalesced inbox task (the trigger's concurrency limit of one, keyed `inbox:<recipient>:<oldest unconsumed sequence>`). |
| `ask` | The sender may block on a reply: a worker's `ask` becomes a question addressed to `agent:<address>`, its work waits, and the reply re-queues it through the existing question → answer → continuation path. Only the dependent work waits. |

Default grants preserve today's behaviour and add nothing cross-host: sessions in the same Mac
project hold implicit `notify` to each other (what `send_to_session` allows now); a manager's
project grant implies `wake` to its children. Every cross-host pair and every worker pair needs an
explicit grant.

`interrupt` is a **priority on the message**, not a mode: it requests steer/next-boundary
delivery and blocks `work_finish`. A grant caps it (`allowsInterrupt`), so an unrelated peer
cannot make every message urgent.

## Bounds

Decided 2026-10-03: **spend is limited where it is spent, and counts are only a loop fuse.**
Sending a message costs nearly nothing; the cost is the work it causes, which varies by orders of
magnitude. So:

- **Spend, at admission** (the real quota). A grant may carry a `SpendCeiling` — the existing
  fraction-of-an-account-window type on manager grants (`ControlAuthority.swift`) — checked
  whenever a mail-triggered wake would start work. The chain ID ties every execution a message
  caused together, and the chain's measured tokens from the
  [usage ledger](agent-usage-ledger.md) count against a chain budget; past it, further wakes and
  sends in that chain are refused. Running work is never stopped by either.
- **No fresh reading → defer.** A wake waits for an account whose reading is fresh and has
  headroom, the way limit recovery waits, instead of starting and failing with `no_account`.
- **No spend check for `notify` or a notice.** `notify` starts no work; a notice inside a running
  turn costs one tool call.
- **A count fuse, set above ordinary use**: 50 messages per chain and 20 sends per minute per
  sender (the managers' existing managed-send rate), both per-grant overridable. It needs no
  reading, so it still stops a ping-pong when readings are missing.

## Storage: inside `ThreadingController`

Decided at implementation: no separate package. `ThreadingController` already builds on Linux
and the Mac app already links it, so the mailbox is part of the controller store (schema v7):

- the controller keeps mail in its own database, so "finish" and "no unacknowledged interrupt"
  share one transaction, as `work_messages` does;
- the Mac app opens a controller store of its own as its mailbox file, under the state directory
  ([`persistence.md`](../architecture/persistence.md) rules: quarantine, no silent recreate).

Records, in the controller's typed-row shape (`kind`, `id`, `parent`, `key`, `state`, JSON
payload, `sequence`):

- `message` — sender-minted UUID (the idempotency key: an identical replay returns the stored row,
  different content is `conflict`), sender and recipient addresses, `replyTo`, chain ID, depth,
  priority, bounded text (32 KiB), `acceptedAt`, `ackedBy`. States `inbox → noticed → acked` on
  the recipient's host.
- `outbound` — per destination host: `pending → handedOff → acked`, with the peer's receipt. A
  lost push response leaves `handedOff`; the next push of the same IDs is an idempotent replay,
  so retry is safe here where it is not for external deliveries.
- `grant` and `peer` (host UUID, display name, SSH destination alias, pinned host key, direction
  `push`/`pull`/`both`, last cursor).

Indexes: unconsumed by recipient, outbound by peer and state, partial on unacknowledged
interrupts. Reading an inbox never walks history; pages are capped at 100 rows / 1 MiB as the
controller's are.

## Transport between hosts: `mail-rpc` over SSH

`threading-controller mail-rpc` reads one JSON request on stdin and writes one response, like
`owner-rpc`, and is run by a **separate, forced-command SSH key** per peer. It has peer authority
only: two operations and nothing else.

- `push { fromHost, messages[] }` → per message `accepted | duplicate | refused(reason)`. The
  receiver checks `fromHost` against the key's pinned host, every sender's host against
  `fromHost`, and grants, then stores. Refusals are durable on the sender as a bounced message
  the sending agent sees in its outbox.
- `pull { forHost, after }` → messages held for `forHost` after a cursor, bounded page.

Because the Mac sits behind NAT, it initiates both directions whenever a remote host is
reachable: push its outbound, pull what the host holds for it. A VPS holds Mac-bound mail until
then. VPS ↔ VPS peers push directly. Mail between two agents on the same host — a worker and a
remote-host session on one VPS — never leaves it, whether or not the Mac is connected. On Linux, the resident `supervise` loop does the syncing
(bounded per tick, as launches are); on the Mac, the app does it while running, on the existing
`RemoteHostTunnel` connection rather than a new one.

Not a new network listener, not `owner-rpc` (an agent's peer must never hold owner authority),
and not the ptyd socket (which carries bytes for a process, not records for a mailbox).

## Delivery, per surface

Adapters run on the recipient's host and turn `inbox` into `noticed`. Which applies is decided by
capability (`AgentKind.capabilities`), never by naming a runtime.

| Recipient | Delivery |
|---|---|
| Native chat, live (Claude stream-json, Codex app-server) | `interrupt` → steer at the next model boundary (`ConversationOutboxCoordination.steer`); normal → the visible queue behind the turn, now backed by the mailbox so a resume no longer discards it. |
| Terminal agent that can answer hooks (Claude, local or remote host), working | A **new, separate** hook command that is allowed to answer: `PostToolUse` returns `hookSpecificOutput.additionalContext` with the notice; `Stop` returns `decision: "block"` with the notice as reason **once per message**, so the turn cannot end with mail unread. Honors `stop_hook_active`. |
| Terminal agent, idle | Today's paste → Return → turn-start receipt, triggered by arrival instead of refused. `.typedUnconfirmed` leaves the message `inbox`, never `acked`. |
| Controller execution, running | The same answering hooks in the recipe's `--settings`, plus `inbox`/`ack` tools on `agent-mcp`, and the finish check. |
| Dormant session / idle worker | `wake` grant → resume or admit inbox work; otherwise it waits, and a `SessionStart` hook notice announces it at the next launch. |
| Terminal Codex, working | The same two answering hooks, in Threading's per-account `<CODEX_HOME>/hooks.json` ([measured](#codex-hooks-measured)). |
| Runtime whose hooks cannot answer (Grok, OpenCode) | Turn-boundary delivery only (the idle row), declared as a capability so the sender's `directory` entry says so. |

**Changing the silent-hook contract is deliberate and narrow.** The existing lifecycle hooks
stay silent and their frozen-text test stays. The answering hooks are additional entries that run
a host binary (`threading-controller mail-notice` / the app's equivalent over the hook
listener), print only host-built notice text or nothing, and are bounded: one notice per message
per surface, at most one `Stop` block per message, and nothing when the inbox has no new
`interrupt`/unnoticed messages. A notice names count, sender display names and hosts — never body
text, which is what keeps contract item 5 true.

### Codex hooks, measured

Measured 2026-10-03 on Codex 0.160.0 under `codex exec`, three real runs in a scratch
`CODEX_HOME`:

- `additionalContext` is accepted on `PreToolUse`, `PostToolUse`, `SessionStart`,
  `SubagentStart` and `UserPromptSubmit`. A `PostToolUse` notice reached the model mid-turn as a
  `developer` message (`hooks.additional_context`) after the tool output, before the next model
  call.
- `Stop` with `decision: "block"` and a `reason` continued **the same turn**: `Stop` fired twice
  with one `turn_id`, `stop_hook_active` false then true, and the reason arrived as a user-role
  `<hook_prompt>` item.
- **Delivery was deterministic; obedience was not.** A small model (low effort) acted on the
  notice in one of two runs and on the `Stop` reason in neither; a larger model acted on both.
- Not measured: the interactive TUI (the hook runtime is in core, so the same is expected).
  Already recorded in [`session-activity.md`](../architecture/session-activity.md): an
  interrupted TUI turn fires no `Stop`.

What follows for the design:

- **A notice is a hint, never the guarantee.** Correctness rests on state the host owns: the
  message stays `inbox` until acknowledged, an unacknowledged `interrupt` refuses `work_finish`,
  and the next execution or turn sees the inbox again. A model that ignores a notice delays mail;
  it cannot lose it.
- **Adding the entries changes `hooks.json`'s text**, so a Codex user re-approves Threading's hooks
  once (`CodexHookInstaller` already handles that moment), unless they opted into
  `bypassesCodexHookTrust`. The notice should ride the existing `PostToolUse` entry's reply
  rather than adding a new command, so the trust prompt happens once.
- `--dangerously-bypass-hook-trust` trusts every hook in that home, not just ours; controller
  recipes for Codex must not use it and should ship a pre-approved hooks file instead.

## Tools

One vocabulary on both MCP servers (the Mac's and `agent-mcp`), so an agent's instructions do not
depend on where it runs:

- `mail_send { to, id, text, reply_to?, priority? }` → the stored message, or a typed refusal.
- `mail_ask { to, id, text, checkpoint }` → a blocking question (workers; the reply answers it).
- `mail_inbox { after }` → bounded page of unacknowledged messages, each framed with its vouched
  header (sender address, display name, host, chain depth).
- `mail_ack { ids[] }`.
- `mail_directory {}` → this caller's address and the addresses it may write to, with mode. On
  the Mac it generalises `list_sessions`.

Named with a `mail_` prefix (decided at implementation) beside the controller's existing
`work_`/`memory_`/`knowledge_` families, so the names do not collide with a provider's own.

`send_to_session` stays as a compatibility wrapper: same-host `send_message` plus today's
immediate live-surface attempt, returning the old outcomes. `watch_session` is unchanged.

Owner operations (CLI and `owner-rpc`): `mail-grant-set`, `mail-grants`, `mail-peers`,
`mail-peer-set`, `mailbox ADDRESS [CURSOR]`, `mail-outbound [CURSOR]`, and
`worker-set-sources … agent` for wake admission.

## Scaling contract

Expected: ≤ 10 hosts, ≤ 100 mailboxes, ≤ 1,000 messages/day. Stress: 100 hosts' worth of peers
configured, 100,000 retained messages, a burst of 1,000 messages into one inbox.

- Accept, inbox page, ack and notice are O(page) or O(1) by index; none reads history.
- A sync tick pushes and pulls at most one bounded page per peer (100 rows / 1 MiB), with at most
  eight peers per tick and a fairness cursor, as the supervisor's launch pass does.
- A hook notice is O(1): one indexed count-and-first-senders query; the hook process has a hard
  timeout and prints nothing on timeout.
- Retention: acknowledged messages are kept until a retention policy exists; message IDs used for
  idempotency are never pruned as ordinary log cleanup (the controller's rule for source keys).

## Rindabox

A consumer, not a special case. Its operations UI reads mailboxes and grants through
`owner-rpc`'s `mail-*` commands and presents them on the agent page ("Can message: <agent> —
notify / wake / ask", owner and admin only, enforced by the server). Its recipes add `inbox`,
`ack`, `send_message` and `directory` to `--allowedTools` only for workers holding a grant, and
the answering hooks to `--settings`. Its prompt tells an agent to read `inbox` at the start of
every execution and to acknowledge what it used. Its own `tasks.team_message` (email to a person)
is unaffected.

## Rollout

1. **Mailbox core, same host.** `ThreadingMailbox`, addresses and host identity, grants, the four
   tools on both MCP servers, `send_to_session` as a wrapper, and busy/dormant becoming "waits"
   instead of a refusal. Delivery at turn boundaries only.
2. **Busy delivery.** The answering `PostToolUse`/`Stop`/`SessionStart` hooks for Claude
   terminals and controller recipes; mailbox-backed native queue and steer for `interrupt`.
3. **Mac ↔ VPS.** `mail-rpc`, peers, and the sync on the Mac's existing tunnel and the
   supervisor loop.
4. **`wake` and `ask`.** `wake` as a trigger on the mail source (after that draft's slice 3), chain
   budget and spend admission from the usage ledger, the count fuse, and
   `agent:` question recipients.
5. **VPS ↔ VPS peers** and the Rindabox UI. Later, if needed: `person:`/`group:` recipients,
   relaying through a trusted peer, expiry for messages nobody acknowledges.

## Tests

- **Core** (scratch databases, no model): idempotent accept with conflicting replay refused;
  grant checked in the accept transaction and revocation effective on the next send; finish
  refused with an unacknowledged interrupt; ack from a stale execution fenced; depth limit and
  in-chain wake refused; coalesced wake surviving restart.
- **Transport**: two stores over a real `mail-rpc` process pair — lost push response replayed
  without duplication; a peer claiming a sender on another host refused; pull pagination across
  1 MiB; offline Mac collecting held mail on reconnect.
- **Delivery**: hook output pinned by test (notice text only, one `Stop` block per message,
  silence on an empty inbox, silence on timeout); a terminal receiving an `interrupt` mid-turn
  and acknowledging it in the same turn — real Claude in `e2e` only; a resumed native chat
  still holding its queued mail.
- **Stress** (opt-in): 100,000 retained messages and a 1,000-message burst; accept, inbox page,
  notice query and sync tick timed before and after manufacture, as the controller's fixtures do.

## Open questions

None remain from the design. Answered 2026-10-03, measured on Codex 0.160.0:

- **A controller recipe can trust exactly its own Codex hooks, non-interactively.** Codex keeps
  hook trust per hook in that home's `config.toml`:
  `[hooks.state."<hooks.json path>:<event>:<group>:<index>"] trusted_hash = "sha256:…"`. The
  app-server's `hooks/list` reports each hook's `key`, `currentHash` and `trustStatus`, and
  `config/batchWrite` (`keyPath` `hooks.state."<key>".trusted_hash`) records trust for that one
  hook. With only that entry written, a real `codex exec` ran the hook without
  `--dangerously-bypass-hook-trust`; editing the hook's text turned it to `modified` and it no
  longer ran. So a deployment that owns a worker's `CODEX_HOME` trusts its notice hooks at recipe
  reconciliation, by hash, and every other hook in that home stays gated. This is the owner's
  decision for a home the deployment owns; the Mac does **not** do it for a person's own Codex
  login, where the trust decision stays the user's (session-activity.md).
