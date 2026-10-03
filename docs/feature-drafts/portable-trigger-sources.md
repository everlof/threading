# Portable trigger sources: wake on facts, not on a model

> Status: **draft** (2026-10-03). Nothing here is implemented. Extends
> [`triggers.md`](../architecture/triggers.md) (the Mac's `listen → match → start` feature) and
> [`autonomous-controller.md`](../architecture/autonomous-controller.md) (whose workers already
> accept an `event` admission source that nothing feeds). Companion to
> [`agent-mail.md`](agent-mail.md), whose `wake` is one source here, and
> [`agent-usage-ledger.md`](agent-usage-ledger.md), which admission reads.

## The problem

Waking an agent should cost tokens only when there is something for it to do. Today:

- The Mac has the right shape and almost no sources. `threading-triggerd` polls without a model,
  writes normalized events with stable identities to an inbox, and `TriggerEngine` matches them by
  typed rules before any session starts — but its one adapter is Sonda's review feed, adapters are
  compiled into the daemon, and the whole path is Mac-only.
- The controller has the admission flag and no producer. `worker-set-sources … event` exists
  (schema v6, `WorkSource.event`); nothing on the host emits events. Recurring work is a schedule
  that runs the model every time, and Rindabox's enqueue timer is an out-of-tree adapter calling
  `automation-run` with a request key.

So "check the support mailbox every ten minutes" today means either a model turn every ten
minutes, or a bespoke script outside Threading with no health, cursor or history.

## Contract: four stages, tokens only in the last

1. **Source** (no model). A bounded, deterministic program observes something — the clock, agent
   mail arriving, an IMAP folder, a feed, a file, a webhook spool — and emits zero or more events,
   each with a stable identity, plus a new cursor. Running it again over the same world emits the
   same identities.
2. **Match** (no model). Typed AND rules over an event's declared fields, as `TriggerEngine` does
   today: "mail from `vps-1/worker/deploy`", "email to support@ whose subject does not start with
   `Re:`". A non-match is a recorded receipt, not a run.
3. **Admit**. Concurrency, quiet hours, the trigger revision's authority, and spend: the grant's
   `SpendCeiling` (a fraction of the recipient account's window), the chain's token budget from
   the [usage ledger](agent-usage-ledger.md), and waiting for an account with headroom instead of
   starting and failing with `no_account`. A missing or stale reading defers; it never guesses.
4. **Run**. The model starts, with the event as untrusted evidence separated from host
   instructions (the existing two-part opening prompt).

**A recurring schedule fires a source, not an agent, by default.** "Every 10 minutes, run the
IMAP probe" spends nothing until the probe finds mail. A schedule that runs the model every time
(a daily report) remains available as an explicit choice; it spends on every occurrence, so it is
always subject to stage 3.

## Sources anyone can write

A source is **an executable on a fixed contract**, so a person can write one in Python, shell or
anything else. Built-in sources (clock, agent mail, the Sonda feed) implement the same contract
in-process.

### The probe protocol

One invocation per poll. The host runs it with:

- **argv** exactly as configured (no shell, no expansion of event or cursor text);
- **environment** exactly as configured plus reserved `THREADING_SOURCE_ID`,
  `THREADING_SOURCE_REVISION`; no inherited environment, like a controller recipe;
- **credentials** by reference only: a configured secret name the host resolves (Keychain on the
  Mac, a `0600` secrets file on Linux) into an environment entry or a file descriptor. Never
  written into configuration that an agent can read;
- **stdin**: one JSON object `{ "cursor": <opaque string or null>, "limit": <max events> }`;
- **working directory**: a private per-source state directory.

It writes **stdout** as JSON lines, then exits:

```json
{"event": {"id": "imap:INBOX:48213", "revision": "1", "occurredAt": "2026-10-03T09:12:00Z",
           "fields": {"from": "kund@example.com", "subject": "Faktura 1123", "folder": "INBOX"},
           "evidence": "first 4 KiB of the plain-text body …"}}
{"cursor": "uidnext=48214"}
```

- `id` (≤ 256 bytes) is the idempotency key; `revision` lets the same item re-fire when it
  materially changes (Sonda's review cycle is this).
- `fields` are typed scalars (string, number, bool, timestamp) the match stage may test; at most
  32 fields, 1 KiB each. `evidence` is ≤ 16 KiB of text shown to the agent, never matched or
  executed.
- Exactly one `cursor` line, last. The host commits the cursor **only after** every event before
  it is durably accepted, so a crash between them redelivers, and idempotent acceptance absorbs it.
- Exit 0 = healthy. Exit 75 (`EX_TEMPFAIL`) = back off. Exit 77 (`EX_NOPERM`) =
  authentication needed. Anything else = failed. Stderr (bounded, 16 KiB) goes to the source's
  health receipt, never to an agent.

Bounds enforced by the host, not trusted from the probe: wall-clock timeout (default 30 s, max
5 min), stdout cap (1 MiB), `limit` events per poll (default 50), minimum interval (60 s), one
in-flight poll per source. Output beyond a cap fails the poll without committing its cursor.

### Trust

A probe runs with the authority of the Unix account that runs the host — it can read whatever
that account can. **It is not sandboxed, and the UI says so.** Therefore:

- A source revision records the executable's resolved path **and the SHA-256 of its content**
  (and of a configured interpreter's script argument, e.g. `python3 probe.py` hashes
  `probe.py`). A changed file pauses the source with "changed since approval" until a person
  approves the new hash. This is the same rule Codex applies to hook text.
- An agent may write a probe and draft a source pointing at it; only the host approval sheet
  (Mac) or the owner CLI/`owner-rpc` (Linux) enables one, showing the path, hash, interval and
  secret names. Agent-authored is never owner-approved by implication.
- Event content is evidence. It never becomes argv, environment, a project, a recipient, a
  destination or a permission — the standing rule for trigger events, work text and mail.

## Where sources run

The same probe contract on both kinds of host, in a portable package
(`Packages/ThreadingDomain` for the types, the runner beside `ThreadingController`'s runtime):

| Host | Runner | Match and admit | Run |
|---|---|---|---|
| Mac | `threading-triggerd` (already owns polling, cursors, backoff, health) gains the generic probe runner; adapters stop being compiled in | `TriggerEngine` in the app (unchanged ownership of `triggers.db`) | ordinary session |
| Linux / VPS | the controller's resident `supervise` loop, bounded per tick like launches (≤ 8 due sources, ≤ 2 concurrent polls) | new controller records: `source`, `source_revision`, `trigger`, `trigger_event`, typed matcher shared with the Mac | `event` work admitted to a worker (`worker-set-sources … event`) |

Each host keeps its own sources, events and history — the [mailbox location](agent-mail.md#mailbox-location)
rule. The Mac's Automations ▸ Remote page reads and approves a host's sources over `owner-rpc`
exactly as it does that host's automations; Rindabox presents the same projection.

## Built-in sources

- **Clock** — today's `AutomationSchedule`, now able to target a source as well as an agent.
- **Agent mail** — a message accepted into a mailbox ([`agent-mail.md`](agent-mail.md)). This is
  what `wake` becomes: "when a message from X arrives for B, admit work for B" is a trigger on the
  mail source, with ordinary matching, admission and history, rather than a special grant mode.
  Coalescing (one open inbox task per recipient) is the trigger's concurrency limit of one.
- **Sonda** — the existing adapter, moved behind the same contract.

Shipped examples, not built-ins (they live under `Examples/` as probes a person copies and edits):
IMAP new-mail, RSS/Atom, file/dir change, HTTP JSON endpoint with an `ETag` cursor, GitHub
notifications.

## Owner operations

Controller CLI and `owner-rpc`: `source-configure ID REV SPEC_FILE` (always paused),
`source-approve ID REV HASH`, `source-enable` / `source-pause` / `source-delete`, `sources`,
`source ID`, `source-events ID [CURSOR]`, `source-poll ID REQUEST_KEY` (one manual poll),
`trigger-configure`, `trigger-enable`/`pause`, `triggers`, `trigger-runs`. Revisioned with
compare-and-swap like workers and automations. No execution-scoped `agent-mcp` tool can create,
approve or enable a source.

## Scaling contract

Expected: ≤ 20 sources per host, polls every 1–15 min, ≤ 1,000 events/day. Stress: 200 sources,
a backlog of 10,000 events on first poll, 100,000 retained events.

- A poll is bounded by the probe caps above; the backlog drains `limit` per poll, never all at
  once.
- Match is O(fields × rules for that source), indexed by source; history is never scanned.
- A tick does a bounded number of polls with a fairness cursor, so one slow or failing source
  cannot starve the rest; repeated failure backs off exponentially to a ceiling, with a health
  receipt.
- Event retention keeps identities forever (dedupe) and drops `evidence` after a retention window.

## Rollout

1. **Probe contract and runner on Linux.** Records, owner operations, supervisor polling, health,
   hash approval; `event` work admission. Rindabox's enqueue timer becomes a probe.
2. **Same contract in `threading-triggerd`.** Sonda moved behind it; the Sources page lists
   probes with hash, interval, health and secrets by name.
3. **Agent mail as a built-in source**, replacing `wake` as a grant mode.
4. **Schedule → source** targeting, and the shipped example probes.

## Tests

Runner as a real process: cursor not committed on crash before the cursor line; redelivery
absorbed; oversized output fails without a commit; timeout kills the process group; `EX_TEMPFAIL`
backs off; a changed hash pauses the source; inherited environment absent; a secret resolved by
name and never echoed into receipts. Match: typed comparisons, missing fields never match. Admit:
spend ceiling refuses, missing reading defers. Fairness: a hanging source does not delay others
past one tick. Stress fixture: 10,000-event first poll and 200 configured sources, timing tick
duration and retained bytes.

## Open questions

- Webhooks: a push source needs a listener, which both hosts deliberately do not have. A probe
  reading a spool directory that something else writes (a reverse proxy, a mail filter) keeps that
  boundary; a real listener would be its own authority decision.
- Should a probe be able to emit a *suppression* ("nothing to do until T") to stretch its own
  interval? Useful for rate-limited APIs; bounded by the minimum interval either way.
