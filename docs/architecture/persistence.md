# The Store, Diagnostics and Drafts

SQLite, quarantine, the durable journal and the composer draft.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

Projects and sessions live in **SQLite** (`threading.db`), not in `projects.json`. The system
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

The panel payload (`PersistedPanel`) carries **both tab hosts** for a session: the display
panel's tabs (`host` absent — which is what every pre-drawer layout implicitly says, so old
rows migrate by decoding) and the drawer's (`host == "drawer"`, plus `drawerActiveTabID` and
`drawerOpen`). Each host saves only its own slice (`saveLayout` / `saveDrawerLayout` preserve
the other's), and the agent-facing `signature`/`agentDescription` filter to panel tabs so the
user rearranging their drawer never re-briefs an agent about a panel that did not change.
Never delete on decode failure; the `try?`-and-fall-back posture stands.

Quarantine still works exactly as it did for the document, because `ProjectStore` never learned
the difference: an unopenable database is moved aside (with its `-wal` and `-shm` sidecars
deleted, or SQLite would recover a fresh database from them) and reported, which is what lets
the store refuse to write over state it could not read.

`ProjectDatabaseTests` imports **the machine's own `projects.json`** into a throwaway database
and compares ids, order, titles, accounts and resume identifiers. A fixture proves the code
path; that one proves the file the user will actually migrate, which is the only copy they
cannot get back.

**The same rule reaches the small stores**, and it had to: `ShortcutOverrideStore` and
`AccountPreferencesStore` keep their state as one encoded blob in `UserDefaults`, and both
collapsed *missing* and *unreadable* into one `else { return }`. For a document store the next
write is a save; for a settings store the next write is **any ordinary edit** — so a user whose
bindings failed to decode lost every one of them, permanently, the first time they rebound a
key. Both now keep the unreadable bytes under `<key>.unreadable` (`DefaultsQuarantine`) and
permit writes only if that keeping succeeded, which is `stateWritesAllowed` in miniature.

A related ordering trap lives one layer up. `AppSettings`'s **`nonisolated static` readers go
straight to `UserDefaults.standard`**, while the seeded defaults were registered only in its
`init` — so a read that happened before anything touched `AppSettings.shared` saw an
unregistered key, and `bool(forKey:)` answers `false`, which for every seeded setting is the
*opposite* of its documented default. The sidebar's branch grouping is what showed it. The seeds
are registered by the readers themselves now; registration is idempotent, and an invariant that
depends on instantiation order is not an invariant.

## Diagnostics and Drafts

Both exist because of one crash (22 July 2026), and each answers a different half of it.

`ThreadingLogger` is `os.Logger` and is the *live* view — `log stream` while a bug reproduces.
It is useless afterwards: `os_log` keeps `.debug` and `.info` in a memory ring buffer, and
only `.error`/`.fault` reach disk. Measured after that crash, `log show --predicate
'subsystem == "codes.threading"'` returned **not one line** for the minute the app died in.

`EventLog` is the durable half: JSONL under `Logs/threading-<date>.jsonl` in Application
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

## Subagent Navigator Snapshots

Child transcript contents remain provider-owned JSONL, but their navigator metadata has to
outlive a renderer: Native → Terminal destroys one controller and starts another, and Codex
app-server offers no durable child index to query afterwards. `SubagentStateStore` writes one
versioned JSON snapshot per session under `Subagents/<session-id>.json`. It contains descriptors,
states, progress and bounded recent activity only; conversation rows are replayed lazily from
the stored provider transcript path. Progress updates are coalesced before atomic writes, so a
busy child does not turn telemetry into synchronous disk churn.

The same `SubagentSessionState` object is retained by `AgentRuntime` across an in-app renderer
switch, preserving live details without a disk round-trip. A full app relaunch loads the compact
snapshot and changes unfinished children to Stopped: persistence proves they existed, not that
their terminated process is still working. Deleting sessions calls `retainOnly`, which removes
both the runtime state and orphaned snapshot files. An unreadable snapshot is moved aside with
an `.unreadable-<uuid>` suffix before new state may be written; if quarantine itself fails,
writes for that session remain blocked rather than overwriting the only recoverable bytes.
Removing a session also invalidates its in-memory state before deleting the file. This matters
because token accounting finishes off-main: a late completion must not recreate a snapshot for
a session that no longer exists.
