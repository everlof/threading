# Observed work for terminal sessions

> Status: **partially shipped** (2026-08-14). Feed A — the resumable transcript scan, its persisted
> resume point, and the three triggers — is implemented for Claude and Codex, and its durable
> decisions live in [`mcp-and-display.md`](../architecture/mcp-and-display.md). What remains is
> drafted below and unbuilt: the honest empty state for a session with no source, the git-observed
> neutral floor, and the OpenCode/Grok export feed, which is still gated on measuring those
> exports. The rest of this file is kept as written so the reasoning behind the shipped half, and
> the shape of the unshipped half, stay together.

## Summary

The Activity tab's **Observed work** card, its file atlas and its activity tree are fed from one
place: the native conversation transport. A terminal session writes nothing to
`AgentWorkTraceStore`, so the panel loads the repository atlas, draws the full silhouette, and
reports `0 of N files · 0 edits · 0 reads · 0 actions` — which reads as a broken panel rather than
as a surface with no data source.

Measured on this machine, 2026-08-14: of the Threading project's 183 sessions, **179 are
`nativeUI: false`**. Its trace file (`~/Library/Application Support/Threading/AgentWork/<project
id>.json`) holds 4 sessions, 3 of which carry any counts. The panel is empty for the overwhelming
majority of real chats.

Nothing about the *model* is native-only. `AgentFileActivityClassifier`, `AgentSessionWorkTrace`,
the bounded worker, the presentation cache and the tree projection are all provider-neutral
already; what is missing is a second feed for sessions Threading does not render itself. The
sampled session's transcript — 906 KB, 57 `tool_use` blocks — is sitting on disk with everything
the panel wants in it.

## What is missing today

The store has exactly three write sites, all inside the native conversation controller:

| Site | What it delivers |
|---|---|
| `ConversationViewController.swift:1281` | `record(providerEvent:)` — the provider callback transports |
| `ConversationViewController.swift:1307` | `record(streamEvent:)` — the in-stream tool calls |
| `ConversationViewController.swift:1820` | `seedReplayIfEmpty(...)` — one bounded replay on start |

A terminal session builds no `ConversationViewController`, and its tool calls exist for Threading
only as PTY bytes. The atlas comes from `GitReviewReader.repositoryFiles` and is independent of the
trace, which is why the grid still draws — an empty reading over a complete repository.

`ExecutionAuditStore` has the same gap for the same reason (the sampled session has no
`.audit.jsonl`), and is deliberately **not** in scope here — see *Scope boundaries*.

## Product contract

- A terminal session's Activity tab shows the same reading a native one does, at **turn**
  granularity rather than per call. A turn that ends is a turn whose work is visible.
- **Never claim what was not observed.** Exact per-file tool signals stay exact. A file whose
  identity was inferred from a repository delta rather than named by a tool is recorded as an
  observed change, is legended as one, and never becomes a read.
- **No new per-tool hook.** Every hook is a process spawned on the agent's own turn boundary
  (`HookLifecycle.swift:12`); a `PostToolUse` hook on every tool would buy this panel with the
  user's latency on every `Read`. The turn boundary Threading already registers is enough.
- **Unavailable is not empty.** A session whose runtime has no work source says so, instead of
  reporting zeros over a full atlas.

## The feeds, by runtime

Expressed as a capability, never as a `kind == .claude` comparison — that shape fails
`scripts/check_architecture_boundaries.sh`, and the capability/implementation pair is held in
agreement by `AgentCapabilitiesTests` (see [`sessions.md`](../architecture/sessions.md)).

### A. Local transcript — Claude, Codex

Both have measured local JSONL and a concrete adapter behind `.transcriptReplay`
(`TranscriptReplayFormat`, `TranscriptReplay.swift:9`). `TranscriptReplay.load` already resolves a
session's file through `SessionTranscript.url` without caring whether the session is native — it
needs `resumeState.transcriptID`, which a terminal session has.

- Reduce **from the records**, not from `[StreamEvent]`, so each call keeps its own timestamp and
  its provider call id. The existing replay reducer (`AgentWorkTraceStore.swift:764`) stamps
  everything `Date.distantPast` precisely because `StreamEvent` carries no time — correct for its
  purpose, wrong here, where recency is the reading.
- Live trigger: the lifecycle `turnFinished` hook, which terminal sessions already carry when the
  user has reporting on (`AgentLauncher.swift:951` for Claude, `CodexHookInstaller` for Codex).
  The payload even names the file — `HookLifecycleReport.transcriptPath`.
- Fallback trigger, and the only one needed for a session that has exited: hydrate when the
  Activity tab is created (`DisplayPaneController.makeFiles`) and on session selection.

### B. Supported export — OpenCode, Grok

Neither has a replayable local format, but both have an `export` subcommand Threading already runs:
`SessionMigration.runExport(kind:transcriptID:projectFolder:loginShellPath:)`, which the Usage
index uses for OpenCode today (`TranscriptUsageService.swift:793`).

- **Needs measurement before this feed is promised.** `OpenCodeUsageAdapter` reads only
  `messages[].info`; whether `messages[].parts` carries tool invocations with their inputs is
  unmeasured here, and Grok's export shape is unexamined for the same question. If the tool inputs
  are not in the export, these two runtimes fall through to feed D and this section becomes a
  recorded *no*.
- An export is a spawned CLI process, so it is never on a per-turn path for a background session.
  Cache by the session's `lastActiveAt` revision the way the usage scan does (`UsageScanCache`),
  and refresh on tab open and on the selected session's turn end only.

### C. Cursor — nothing to do

`.terminalUI` is withheld (its TUI and ACP keep disjoint conversation stores), so every Cursor
session here is native and already records live.

### D. Neutral floor — git turn checkpoints, every runtime

`GitTurnBaselineStore.noteActivity` is driven by the terminal container's own activity edges
(`MainWindowController.swift:3969`) and carries an explicit fallback for *a terminal whose
lifecycle hooks are unavailable* (`GitTurnBaselineStore.swift:163`). Every terminal session of
every runtime therefore already has before/end trees per turn.

That yields the turn's changed paths — including the shell edits no tool ever named — with no
reads and no per-call attribution. Recorded with `observed` provenance, legended distinctly, and
never merged into the read/edit counts as if a tool had reported it.

## Architecture it extends

- **New capability** for "Threading can derive observed work for this runtime without rendering
  it", with `AgentCapabilitiesTests` holding it to the adapter set, exactly as `.transcriptReplay`
  is held to `TranscriptReplayFormat`.
- **One new type** — a hydrator owning "reduce this session's source into its trace from a resume
  point" — plus its triggers. Everything below it exists.
- `AgentProjectWorkFile` gains a per-session **resume point** (byte offset, or the last consumed
  record's uuid). That is a format-version bump, which is cheap: the file is a
  `.rebuildableCache`, and an unsupported version already rebuilds rather than fails.
- `.seed` becomes a merge. Its current guard refuses any non-empty trace
  (`AgentWorkTraceStore.swift:891`), which is right for a one-shot replay and would freeze a live
  terminal session at its first reading.

## Scope boundaries and risks

1. **Idempotence across restarts.** The in-memory `seenCalls` dedupe does not survive a relaunch,
   so re-reading a transcript must be bounded by the persisted resume point, not by call ids alone.
2. **Scaling gate.** The sampled transcript is 906 KB and `ReplayDefaults.scanLimit` is 64 MB. A
   naive re-read is O(file) per turn; the resume point makes the steady state O(new bytes). All
   reduction stays on the worker's queues, and the main actor keeps receiving one bounded delta —
   the store's existing contract. Export-based hydration is on-demand only.
3. **Shell edits stay unattributed in feeds A and B.** The classifier deliberately lights only
   files a tool named exactly (`AgentWorkTrace.swift:17`). This is not a regression to fix here;
   feed D is where those files appear, marked as what they are.
4. **Honest empty state.** Today an unavailable source is indistinguishable from a session that did
   nothing. The card needs a third state beside loading and populated.
5. **Execution Audit is a separate slice.** It shares the cause and would share the feed, but it
   carries redaction and hash-linked storage rules of its own; read
   [`execution-audit.md`](../architecture/execution-audit.md) before extending it.
6. **Concurrent work.** `GitTurnBaselineStore` is under active change (per-call edit claims,
   turn-overlap stamping). Feed D consumes its published checkpoint API and adds no second reader
   of its internals.
7. **Privacy is unchanged.** Paths and tool names only, the same facts the panel shows for native
   sessions today; no file content and no command text beyond the existing ribbon.

## Tests

- Incremental merge: idempotent across repeated reads and across a simulated relaunch; a top-up
  after new records adds only the new work.
- Timestamps survive the reducer, so heat and recency are real rather than `distantPast`.
- Per-format reducers against Claude and Codex fixtures — `CodexPatch` multi-file patches are
  already covered by `FileActivityMapTests` and must keep yielding every file they touch.
- Capability and adapter set in exact agreement (`AgentCapabilitiesTests`).
- The unavailable-source state rendered light and dark (`FileActivityMapRenderTests`).
- An opt-in stress fixture: a multi-megabyte transcript hydrated on tab open, then topped up per
  turn — measuring background reduction, main-thread mount, live view count and footprint.

## Rollout

1. ~~Feed A with the resume point, triggered on Activity-tab open.~~ **Shipped 2026-08-14.** Covers
   Claude and Codex with no dependency on the user's hook setting, and is the slice that turns the
   panel on for 179 of 183 sessions here.
2. ~~`turnFinished` top-up, so a live terminal session updates as it works.~~ **Shipped**, plus the
   inferred activity edge, which covers a session whose runtime or user has no lifecycle hooks.
3. The unavailable state and the provenance legend. **Next**, and the one piece of the shipped half
   that is still dishonest: a Grok or OpenCode terminal session reports zeros over a full atlas
   exactly as before, because nothing feeds it yet.
4. Feed D, the git-observed floor, for every runtime.
5. Measure the OpenCode and Grok exports; add feed B if the tool inputs are there, and record the
   negative in [`docs/decisions/`](../decisions/README.md) if they are not.

## What shipping feed A changed about this draft

- **No new capability was needed.** `.transcriptReplay` already means exactly "a normalizable local
  conversation exists for this runtime", which is the fact this feed turns on, so it rides that
  rather than inflating the matrix. A capability of its own is earned when feed B adds a *second*
  kind of source, and `AgentCapabilitiesTests` will hold it to its adapters then.
- **No format version moved.** `transcriptOffset` is optional and additive, so an existing cache
  file decodes with it absent — which is precisely "never hydrated", the state the rules already
  had to handle.
- **The delta must not be merged wholesale.** The first implementation folded a delta trace in and
  called `rebuildDirectories()`, which is O(every file every session in the project has touched),
  per turn. Calls now go through the same incremental path a live event takes.
