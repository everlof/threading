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
same fact two homes is how one of them goes stale. Standalone `ProjectTerminal` records remain
embedded in that project payload: they are small project-owned sidebar destinations with no
transcript or independently queried lifecycle, so a separate relational row buys nothing.

Writes are **per row, in one transaction**: upsert what is there, delete what has gone. That is
the actual gain over the document — the store is no longer rewritten in full every time an agent
renames a chat or standalone terminal — and it retires the rolling `projects.json.bak`, whose whole job was
covering the window in which a full rewrite could be interrupted. WAL is the other half: a read
never blocks the writer, and `busy_timeout` turns "another process has it" into a wait. That
makes multiple writers *possible*, not permitted — `SingleInstanceLock` still stands, and is a
chosen concurrency model rather than a workaround.

**SQLite handles have one deterministic lifetime.** `SQLiteDatabase.Statement` finalizes in
`deinit` as well as after `run`: fluent binding can throw while the statement expression is still
being built, before `run` has installed its own `defer`, and that must not leave a native statement
holding the connection open. Both finalization and `SQLiteDatabase.close()` are idempotent, and a
failed database initializer closes the partly configured connection. Owners still close the
connection explicitly at storage boundaries—RAII is the backstop for an abandoned object, not the
ordering primitive for moving a database and its sidecars.

**The import runs once and keeps its rollback.** A `projects.json` is read through the decoder
and migration chain it always used, written into the database in a single transaction, and then
*renamed* to `projects.json.migrated` — never deleted. opencode's own migration is the reason:
an update that recreated its storage directory without migrating took users' legacy sessions
with it. The same applies to the panel layouts, which were `panels/<uuid>.json` and are now
rows; their cached PNGs stay files, because a PNG in a database is a PNG with extra steps.

The panel payload (`PersistedPanel`) carries **every tab host** for a session in one flat list,
told apart by each tab's `host`: the display panel's (`host` absent — which is what every
pre-drawer layout implicitly says, so old rows migrate by decoding), the drawer's
(`host == "drawer"`, plus `drawerActiveTabID` and `drawerOpen`), and each detached window's
(`host == "window:<uuid>"`, plus a `detachedWindows` record carrying that window's frame,
selection and fullscreen state). Each host saves only its own slice and **rebuilds `tabs` from
the slices it is not replacing** — the one rule that keeps a flat list with three writers
honest, because a slice no writer preserves is one the next save silently drops. The
agent-facing `signature`/`agentDescription` filter to panel tabs, so the user rearranging their
drawer never re-briefs an agent about a panel that did not change.

**The document validates rather than interprets charitably.** An unknown `host`, a `window:`
host that is not a well-formed id, a tab naming a window the document does not declare, a
duplicate window id, or a window claiming a selection from another host each refuse the whole
document. Every one of those describes a tab that no pane would show and the next save would
drop, so refusing is how that loss stays visible instead of silent.

**`formatVersion` is 2**, raised when detached windows arrived. The bump is the point: a build
that predates them cannot show a `window:` tab, and the version is what makes it say so.

Which is only half an answer, so the other half is here too: `DisplayPaneStore` **quarantines a
payload it could not decode**. `loadLayout` returns nil for "nothing stored" and for "stored but
unreadable" alike, and every writer rebuilds from that answer — so without quarantine, opening a
session written by a *newer* build would read as "nothing stored" and the first save would
replace the user's panel, drawer and windows with whatever this build happened to be showing.
That is the same promise `ProjectStore` makes for the database, kept for this document too, and
it is what makes the version bump a refusal rather than a wipe. Never delete on decode failure.

Quarantine still works exactly as it did for the document, because `ProjectStore` never learned
the difference: an unopenable database is moved aside and reported, which is what lets the store
refuse to write over state it could not read.

**Quarantine first makes the database movable; it never renames a live WAL bundle.** In WAL mode
committed rows can live only in `-wal`, and moving those files from under another SQLite connection
is an API violation: the live connection keeps vnodes for names that no longer describe its
database. Measured under the hosted-test reproduction, that emitted SQLite's “vnode renamed while
in use” warning and made the purported recovery copy timing-dependent. `StateManager` closes its
own handle, then `SQLiteDatabase.prepareForFileMove()` asks SQLite to transition WAL to DELETE
journalling. If another reader pins the WAL, the transition fails and quarantine leaves the
database and both sidecars exactly in place, with writes refused. After the other owner closes,
SQLite folds the WAL into the database; the next launch can move one self-contained file. Recovery
is allowed to wait, never to manufacture a copy by moving files out from under the library that
owns them.

**A future database schema is unsupported, not corrupt.** `SQLiteDatabase` reads
`PRAGMA user_version` immediately after opening and before changing journal mode or running any
migration. A value above `ProjectDatabase.schemaVersion` closes the handle, leaves every byte and
sidecar untouched, creates no `.corrupt` artifact and disables writes for the launch. `migrate(to:)`
repeats the monotonicity check so no alternate constructor can silently accept a future database.

**One unreadable auxiliary row costs that row, not the store.** `panel_layout` and
`session_attachments` used to be validated inside `load`'s all-or-nothing contract, on the sound
reasoning that a document which merely looked *missing* to its feature would be overwritten by
that feature's next ordinary edit. The reasoning was right and the blast radius was wrong: a
failed load quarantines the database, so one panel written by a build a format version ahead
took every project and chat with it — which is exactly what happened, from a row reading
`{"formatVersion":2,…,"tabs":[]}` that a pre-detached-windows build refused. `ProjectDatabase.load`
now returns a `ProjectsStateLoad`: the project graph, plus the rows it could not read. What the
all-or-nothing rule protected is protected one row at a time — `StateManager` reports the row to
its feature as absent so the pane rebuilds, and refuses every write to it for the rest of the
launch, so the bytes are still there for the build that can read them. A row whose `session_id`
is not an identifier at all is tracked apart as `containsUnkeyedRows`, because no feature can ask
for it by id and only skipping the table's prune keeps it. The project and session rows stay
all-or-nothing: those are the copy of record.

Agent execution evidence has different write and trust needs from mutable application state, so it
does not live in SQLite. [Execution Audit](execution-audit.md) keeps a bounded append-only,
SHA-256-linked JSONL chain per session under `ExecutionAudit/`. Its directory and files are
owner-only, rotation is reported as a verified suffix rather than a complete history, and deleting
a session or project synchronously removes all of that session's segments.

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

`RecoverableDefaultsStore` also requires a compact-metadata size policy. `UserDefaults` delivers
the blob as one `Data`, so the app cannot make cfprefsd stream it, but the 1 MiB ceiling is checked
before JSON decoding/materialization and again before replacement. Change-request repository
policy, publish receipts, the usage-window schedule and the selected extension navigator use this
same envelope now; none can turn corrupt bytes into an empty value that the next ordinary edit
overwrites. Each builds and validates a candidate, persists it, and only then publishes the
in-memory state and any change notification. Navigator identity is bounded and nonempty, so an
invalid extension selection cannot displace the last durable route.
The usage schedule additionally bounds its minute fields, weekdays and account set because that
preference can authorize background work that spends an account's limit: a malformed or refused
write must leave both the last durable and the currently active schedule unchanged.

File-backed `RecoverableFileStore` adds a separate required size policy: 1 MiB compact metadata,
32 MiB user documents, or 64 MiB derived caches. Reads and post-write verification go through the
same streaming one-byte-past-limit boundary; encoded values over the declared policy are refused
before replacement. Criticality still decides whether an unreadable predecessor is quarantined or
a cache is discarded. Size and recovery value are separate facts, so adding a store cannot make it
unbounded merely by choosing the right preservation behaviour.

A related ordering trap lives one layer up. `AppSettings`'s **`nonisolated static` readers go
straight to `UserDefaults.standard`**, while the seeded defaults were registered only in its
`init` — so a read that happened before anything touched `AppSettings.shared` saw an
unregistered key, and `bool(forKey:)` answers `false`, which for every seeded setting is the
*opposite* of its documented default. The sidebar's branch grouping is what showed it. The seeds
are registered by the readers themselves now; registration is idempotent, and an invariant that
depends on instantiation order is not an invariant.

## The Pre-Rename Directory

The rename to Threading moved the Application Support directory with the app —
`Skalman/skalman.db` became `Threading/threading.db` — and nothing carried the old one across.
The first launch afterwards came up on an **empty store**, with the projects, sessions, panels,
per-session settings, installed extensions and usage history all still in the old directory. It
does not read as data loss, which is what made it dangerous: the app looks new rather than
broken, and the next actions write over the top of an empty store while the real one goes stale
beside it. Measured on the machine that hit it: 5 projects in `skalman.db`, 0 in `threading.db`.

`LegacyApplicationSupportMigration.runIfNeeded` runs from `applicationDidFinishLaunching`, after
the single-instance lock and the launch marker, and before any store is opened.

- **The gate is that the new store has no projects.** That is the one signal saying the new
  location has never really been used, and it is what makes adopting the old one safe: there is
  nothing here to lose. A store with projects is left alone entirely — an old directory must
  never reappear over work someone has already done in the new one. The database is *opened* to
  ask, not measured by size: the build that created this file wrote a 4MB journal without ever
  storing a project.
- **Inside the gate the legacy copy wins each conflict**, because anything in the new directory
  came from a build that had already lost its state. Files that exist only in the new directory
  survive, so a genuinely new install sitting beside an old one keeps what it has.
- **Copied, never moved.** A bad adoption costs a directory of disk rather than the only copy of
  anything, and a pre-rename build still running from someone's Xcode keeps its open files.
  `FileManager.copyItem` clones on APFS — the 143MB extension tree copies in 0.15s and shares
  its blocks — so the cost of not moving is close to nothing.
- **The database is copied with its `-wal` and `-shm`**, then read back. A database copied
  without its journal loses every committed transaction still in it, and a hot copy of one
  another process is writing can arrive torn. There is nothing to restore if it does, since the
  gate established the store here was empty, so a failed adoption removes the copy and the app
  starts fresh exactly as it would have.
- **The marker (`.adopted-from-skalman`) is what makes it one-shot**, so someone who
  deliberately started over is not handed the old state back on the next launch. It is withheld
  when a legacy database was present but did not arrive, so a full disk gets another attempt
  rather than being recorded as a migration that happened.
- The old lock file, the old `Logs/` directory, and any `.migrated` file an earlier migration
  already retired stay behind. The journals are a record of what *other processes* did rather
  than state the user owns, and the launch marker among them is read by the adopting launch as
  its own crash report — see "What the marker covers" below.

**The `UserDefaults` domain is a separate orphan and is not imported wholesale here.** The bundle
id went `se.mjukis.Skalman` → `codes.threading`, so the theme choice, custom palettes, terminal
profiles and account preferences are still in the old domain. Overwriting live preferences is a
different risk from adopting an unused directory, and it needs its own decision. There is one
narrow carry: a legacy `installsCodexHooks = true` is copied only when the current domain has no
value. That preference authorises maintenance of hooks the same product already wrote; without
it, Codex falls back to the PTY quiet heuristic. Threading exports the old `SKALMAN_*` hook
routing aliases beside `THREADING_*`, so an exact old hook remains runnable without rewriting
its trusted command text. The old hook-trust bypass is carried too only when hook installation
remains enabled: both were separate explicit choices before the rename, and current values win
independently. No other preference is imported by this migration.
Like every startup migration, this import is disabled in the hosted XCTest process: that bundle
runs inside the shipping app and sees the developer's real defaults domains, so importing there
would mutate the next real launch merely because a unit test constructed `AppSettings.shared`.

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

**Every unified-log interpolation states its privacy.** Relying on OSLog's implicit default is
safe at runtime but ambiguous in review: nobody can tell whether the author classified the field
or forgot. `scripts/check_logging_boundaries.py`, reached by the ordinary architecture/build gate,
therefore refuses an unmarked interpolation and direct `Logger`/`os_log` use outside
`ThreadingLogger`.

- `.public` is for structural machine facts: enum tokens, booleans, counts, durations, status and
  exit codes, ports, schema versions and opaque session/project/turn identifiers. These are the
  fields a persisted error needs in order to remain actionable.
- `.private(mask: .hash)` is for values useful only by correlation: paths and filenames, URLs,
  account handles/ids, command arguments, extension-supplied diagnostics and arbitrary
  `localizedDescription` text. Errors can embed a path, URL or response excerpt even when the
  static error type looks harmless.
- `.private` is for content that is useful only during an explicitly privacy-enabled live
  reproduction, such as prompts and provider response bodies. Bearer tokens, credentials,
  filled browser values and raw client log text are not logged at all; marking a secret private
  is not permission to collect it.

The lint also refuses known content/path/account expressions marked public. It is deliberately a
floor rather than a data-flow engine: a locally named `reason` still has to be classified by the
reviewer who knows whether it is an internal enum token or untrusted prose.

**Levels describe impact, not how interesting a line is.** `debug` is repeatable detail and
high-frequency observation; `info` is an expected successful boundary; `notice` is an uncommon
but healthy transition worth retaining; `warning` is a recoverable refusal or degraded fallback;
`error` means the requested operation failed or durable state needs recovery; `fault` is a broken
invariant or data-safety failure. A retry that succeeds stays debug/info, while a swallowed error
does not become harmless merely because the UI has no alert.

**Categories name the owning subsystem, not the screen that happened to call it.** Process and
conversation lifecycle use `agent`/`session`; repository probes and mutations use `git`; embedded
browser state and automation use `browser`; app/terminal themes and reclaimable disk data use
`theme`/`storage`; and remote access, extensions, MCP, updates, usage and the execution audit each
have their own category. A low-level helper used by several screens logs under that owner once;
the screens do not duplicate the same failure under a UI category.

`EventLog` is explicitly different: it is the owner-local post-mortem journal and its schema can
contain commands, paths and submitted prompts. It is never attached to the share-safe remote
diagnostics route. That exception does not extend to unified logging, support reports or hosted
telemetry.

**The journal's descriptor is opened `O_APPEND`, not seeked to the end.** More than one
process writes this file: a hosted XCTest bundle runs inside the real application, so a test
run journals into the developer's own `Logs` directory while the app is running. Two
`FileHandle`s then hold two offsets over one file, and each writes straight through what the
other appended after it opened. Measured on the 5 August 2026 journal: 23 lines unparseable,
and a quit's own `Quit` record overwritten mid-line by a concurrent `scripts/test.sh` — which
read as "the quit never ran" and cost a debugging session, since the whole point of this file
is to be believed after the fact. `O_APPEND` moves the seek into the kernel, where it is
atomic with the write.

A launch writes a marker that only `endLaunch` removes, so the *next* launch is what reports
`Previous launch did not quit cleanly` — consumed on read, so one death is one record rather
than a standing complaint, and it carries the path of the matching `.ips` from
`~/Library/Logs/DiagnosticReports/`. The `Quit` record carries `runningSessions`, the count
handed to the next launch's relaunch; see [`sessions.md`](sessions.md).

**What the marker covers is decided by where `beginLaunch` sits**, since it only catches a death
that happens after the file is written. It is now the first thing an instance does once it owns
the state — immediately after `SingleInstanceLock.acquire()` and **ahead of** the pre-rename
adoption, which used to run inside the blind window and is the one part of a launch that moves a
user's database around.

Two prefixes stay uncovered on purpose:

- **The hosted-test bail-out.** `applicationDidFinishLaunching` returns at its first line under
  `XCTestCase`. A test run must never write the marker: the bundle is hosted in the real app and
  journals into the developer's own directory, so a test host writing one would leave the app's
  next launch reporting a crash that was a `scripts/test.sh` finishing.
- **Everything before the lock** — `main.swift`, `NSApplication` setup, the launch span. A marker
  written before we know we own the state is a marker written *on behalf of another process*,
  which is the hazard below. Covering it would need a per-process file, which is a different
  mechanism from the one this file is.

**Ending a launch is gated on having begun one, in `EventLog` itself.** The marker is a single
file and more than one process reaches a quit path here: the instance that loses the
single-instance lock puts up an alert and terminates, and the lock fails open, so two live
instances are possible rather than impossible. Removing the file from a process that never wrote
it would tell the *running* instance's next launch that its crash had been a clean quit — the one
thing the marker exists to catch. So `beginLaunch` mints a per-launch token, writes it into the
marker and holds it; `endLaunch` refuses outright without one, and removes only a file still
carrying its own token. The lock loser's `applicationShouldTerminate` guard is still there and
still correct; it is now a second line rather than the only one. `beginLaunch` is also once per
process — beginning twice would read back the marker written moments earlier and report the
running process as a crash.

**Why the adoption can now follow it.** `LegacyApplicationSupportMigration` keys on three things:
the legacy directory existing, its own `.adopted-from-skalman` marker, and the *database* in the
new location being absent or empty. `EventLog` writes none of them, and the directory the
adoption would otherwise have to create was already made by `SingleInstanceLock.acquire()` a few
lines earlier — so the ordering swap cannot change what the adoption decides. What it did
interact with was the copy: `Logs/` came across with everything else, and **that was a bug in its
own right**. Measured on the real adoption of 30 July 2026, the legacy `Logs/launch.json` was
copied in and read seconds later as this launch's unclean exit, reported with a pid, a start time
and a version belonging to the app under its old name, and matched to a `Threading-*.ips` written
by an unrelated process. The mechanical half is worse: this launch's journal is open for
appending by the time the adoption runs, and replacing a file under an open descriptor detaches
every record written after it, silently. `Logs/` is left behind now, which loses nothing — the
legacy directory is copied rather than moved, so the old journals stay readable where they were
written.

**A launch that leaves without quitting is a third disposition, not a crash.** The reset flows
`exit` rather than terminate — `AppRelaunch` above — and that leaves the marker exactly where a
crash would. It cost nothing while the marker was only read for a support field, and it became a
bug the moment the launch after a crash started acting on it: **Reset Settings does not move the
support directory**, so its marker survived the restart, the next launch held the workspace back
and put a crash notice across a window the user had just pressed a button to get back. (Reset
Everything was accidentally fine: the directory moves and the marker goes with it.)
`AppRelaunch.recordIntentionalExit` **stamps** the marker with a disposition instead of removing
it — removing it would say "quit cleanly", which is what the quit path means and this is not —
and `PreviousLaunchOutcome` grows an `.intentional(reason:)` case that restores in full and says
nothing. The stamp is written inside `PreparedRelaunch.commit` rather than at the reset call sites,
so a third caller cannot forget it, and immediately before `exit`, because everything between the
stamp and the exit is a window in which a real crash reports as a deliberate restart.

## The Launch Ledger

The marker answers one question — did the last launch come back — and answers it once. What it
cannot say is how far that launch got, or whether this is the third one in five minutes.
`LaunchLedger` is that record: `Launch/launch-ledger.jsonl` under the support directory, a `begin`
per launch, a line per startup checkpoint, and an ending.

**Append-only over `O_APPEND`, not `RecoverableFileStore`'s atomic whole file.**
`AgentChildLedger` takes the other shape and is right to — it describes what is running *now*, so
rewriting the whole value costs one small file. This one describes what happened, it grows through
a launch, and it has to survive the process dying between two of its own writes. A whole-file
store also cannot survive a second writer, which a hosted test bundle already is and which Phase 3
deliberately introduces. Its own directory rather than beside the journal, because `EventLog`
prunes *any* `.jsonl` in its directory past the retention window, and a quarantined copy a
neighbour deletes is not a quarantine.

**The version is per record, not per file.** A supervisor's records will land beneath this build's
in one file, so a record a reader cannot parse has to be skippable without the file becoming
unreadable; `writer` says who authored each one. The enum-valued fields are stored as raw strings
and read through typed accessors, because a checkpoint name a build has never heard of is a record
it does not understand rather than a corrupt file, and `JSONDecoder` cannot tell those apart.

**Four read outcomes, and the third is the one that had to be argued for.** Missing is missing. A
torn *final* line is dropped and flagged — that is what dying between two writes looks like, and it
is the signature this file exists to record. A line that failed anywhere else is damage, and damage
is moved aside; if it cannot be, writing stops rather than continuing beside data the store has
just proven it cannot manage. A record from a *later* Threading is none of those: the file is left
byte for byte, counted, and the policy stands down. A later format beats damage in the same file,
because the cost of being wrong about damage is a moved file and the cost of being wrong about a
newer build is its history.

**Tombstones are written by the successor**, because the process that died is the one that cannot
write its own ending. At `beginLaunch` **every** `begin` lacking both an `end` and an `outcome`
gets one: the newest takes the marker's answer, since `EventLog` is the one thing that actually
knows how the last launch ended, and older ones are inferred `unclean` from their own missing
`end` — that absence is the evidence and it needs no marker, which matters because the case that
produces an older unfinished `begin` is a successor that died before it could write anything at
all. A marker answer with **nothing unfinished to attach to writes nothing**: inventing a target,
or hanging an outcome on a launch that already ended, would make the file say something nobody
observed. `CrashLoopPolicy` also treats an untombstoned `begin` as an unexpected exit, so a
missing tombstone can never hide a crash.

**Eviction is by launch, never by line.** Half a launch reads as a launch that died, so a line
budget alone would manufacture the exact fact this file exists to report. Twenty launches, with a
512-record ceiling as the second guard, compacted at the one moment a rewrite is safe: a single
writer, before this launch has recorded anything, and with a failure that leaves the old file to
be appended to. Compaction moves to the supervisor in Phase 3 with `begin` and `outcome`.

`CrashLoopPolicy` is a pure function from that history to a typed decision, because every
interesting input — a second crash four minutes after the first, a clock stepped backwards between
them, a reboot in the middle — is a situation nobody can stage on demand. It walks backwards from
the newest launch and stops at a different build, at a launch that reached `stable`, or at a pair
outside the five-minute window. **Never-counted is not "resets the counter"**: a clean quit, a
logout, a reset relaunch and an ending this build cannot name are all skipped *through*, because a
quit thirty seconds into a launch is not evidence anything was fixed. Only ten interactive minutes
is. **The window bounds only the pairs that both reached readiness** — a launch that died before
its first window cannot be something the user did, and an app that cannot start is not more
startable for having been left alone overnight. Uptime within one boot session (it advances across
sleep, which is what "five minutes of the user's time" means, and survives the clock being set),
the wall clock across a reboot, and an unknowable or negative interval counts as *outside*: a
clock that moved backwards must not manufacture an escalation.

The lock-losing instance and the hosted test bundle are covered by construction rather than by a
guard at each call site — `beginLaunch` sits after `SingleInstanceLock.acquire()` and below the
`XCTestCase` bail-out, so neither ever opens a launch, and a checkpoint arriving without one is
dropped. The ledger's URL also redirects under a hosted bundle, `AgentChildLedger`'s rule: either
alone has been shown insufficient here.

The decision is journalled, carried in the support report beside `previousLaunchClean` as counts and
enum tokens, and picks between two sentences in the unclean-exit notice. What the app *does* about
it — the two-step open that lets a `begin` carry the launch's mode, Recovery Mode, and the one-shot
flags beside this file — is [`crash-recovery.md`](crash-recovery.md)'s. This file keeps the format,
the durability and the quarantine.

`DraftStore` keeps composer text per project. That text is the one thing in the app that
exists nowhere else while it is being written: no transcript (the agent has not launched), no
scrollback (there is no terminal), no shell history (the login shell `exec`s the agent). It
is written **on the keystroke, not on a timer** — the opposite of `ProjectStore`'s coalesced
saves, and for the opposite reason: the file exists *for* the crash that lands between two
keystrokes, so a coalescing window is the one interval it cannot afford.

Submitting records the prompt to the journal *before* clearing the draft. Clearing first
would reopen the original hole — the prompt would live only in memory and in a command line,
which is precisely where it was when the crash took one.

Attached images are **not** drafted: a pasted screenshot is a file in a temporary directory,
and a path written to disk now can name nothing by the next launch. They survive instead by the
composer being kept as it was left for as long as it is pointed at the same project — see
[`sessions.md`](sessions.md), which is also where the bug that rule fixes is recorded.

`SessionContinuityStore` applies the same criticality rule to an already-running Native session.
Its `session-continuity.json` entry is keyed by `SessionID` and writes an unsent conversation draft
immediately; viewport progress is cheaper and is coalesced. Transcript content remains in the
provider-owned session, so this file stores only the private local draft, normalized reading
position, follow-bottom choice, and update time. Clearing a submitted draft preserves the
viewport. An unreadable file follows `RecoverableFileStore` quarantine rather than being replaced
silently.

The companion clients use the same contract with a wider key. iOS stores a versioned archive in
its own `UserDefaults`; the dependency-free browser stores one in same-origin `localStorage`.
Both length-prefix the paired host identity before the session id so ids cannot collide, persist
the last host/session route, and keep Native and terminal drafts distinct. A Tailscale/relay URL
is deliberately absent from that key: both are routes to one paired host. Records containing an
unsent draft are never pruned automatically; position-only records are bounded to the 250 most
recent. The iOS archive is also capped at 1 MiB and validates state count, identity, viewport and
aggregate draft bytes before decode is accepted and before encode is attempted. Every mutation is
made against a candidate archive, and that candidate becomes visible only after the `UserDefaults`
replacement reads back identically; a persistence refusal cannot leave the running composer ahead
of its durable draft. The device-local terminal-keyboard archive follows the same candidate-first,
bounded rule. No continuity archive is synchronized across clients, because merging partial human
input or moving another person's viewport would turn safety state into collaboration state.

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

## 2026-07-30 — Where it all is, and starting over

Two file locations hold Threading's ordinary state, and `AppDataLocations` is the only place that
says so: the **preferences domain** (the bundle identifier, `codes.threading`) and one directory,
`~/Library/Application Support/Threading`, which is `StateManager`'s root and therefore also the
store, the panel layouts and their cached PNGs, project icons, avatars, usage history,
icon-research records and the instance lock. Settings ▸ **Advanced** shows both and reveals them,
because "where is my data" is a question answered with a path to copy rather than a sentence.

Security capabilities are the deliberate third category. Native owner-device records, including
their 256-bit bearers, live in one versioned login-Keychain item with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; the paired iPhone keeps its side in its own
Keychain. A decode or write failure is fail-closed: the app neither overwrites an unreadable item
nor issues a credential it cannot persist. Turning Remote Access off clears runtime authority but
does not unpair devices. Named revocation writes Keychain first, then drops live authority and
sockets, so a failed revoke cannot appear successful and return after restart.

The browser's **test credentials** are the second store in that third category, and the one whose
placement is a decision rather than a default. `BrowserCredentialStore` writes generic-password
items under `codes.threading.browser.credential`, preferring `kSecUseDataProtectionKeychain` —
which puts them out of reach of `security add-generic-password` and `security
delete-generic-password`, since the CLI cannot address that keychain at all and this app launches
agents with an unrestricted shell. That keychain needs an entitlement an ad-hoc-signed build does
not have, so the store **probes once and falls back** to the login keychain, and reports which one
it got through `isShellReachable` rather than letting a Debug build claim a Release build's
guarantee. It is deliberately separate from `KeychainManager`, which keeps
API keys in the login keychain: moving those to share one implementation would orphan every key
already saved. Because neither store lives under Application Support, **Reset Everything deletes
each explicitly**; without that, a reset would move the app's directories aside while leaving every
stored credential behind, having told the user it removed the app's state. Under a hosted test
bundle the service name redirects to a scratch service, for the same reason `PreferenceStore`
redirects its suite.

**What is deliberately outside the two.** Anything written into *another* program's folder is not
ours to reset: the Claude status-line cache under `Claudex/ClaudeStatus` is there because that is
where the CLI reads it from, and per-session hook and MCP config files are handed to an agent
process. A reset that swept Application Support for its own leavings would take those with it, so
it never sweeps — it names.

Two resets, because the blast radii differ and offering only the wider one would make a broken
preference cost every conversation. `settings` clears the domain; `everything` also moves the
directory. Three decisions carry it:

- **Moved aside, never deleted** — into `Threading Resets/<yyyy-MM-dd HH-mm-ss>/`, which is the
  posture `ProjectStore` already takes with a database it cannot open. A mistaken reset costs a
  drag back, and a store reset *because* it was corrupt is still there to be read. The folder is a
  **sibling** of the directory it holds: a backup that moves with the thing it backs up is not one,
  and `AppDataResetTests` pins that a second reset cannot carry off the first one's.
- **Preferences go through `UserDefaults`, not the file.** `cfprefsd` owns the plist and holds the
  domain in memory, so a file moved out from under it is written back — the reset would appear to
  work and undo itself at the next flush. The domain is serialised into the backup first, then
  `removePersistentDomain`.
- **The app restarts, and leaves without saving.** Every store here is a singleton holding its
  state in memory, so a running app carries on from what it read at launch and would write the
  projects, the layout and the session list straight back into a fresh directory. `AppRelaunch`
  therefore `exit`s rather than calling `NSApp.terminate`, which is the only path in the app that
  does — discarding is the whole point, and a polite quit would undo it. It also spawns a detached
  `sh` that waits before opening the bundle, because `SingleInstanceLock` is an `flock` held for
  the process's lifetime and a copy started too early sees the lock and refuses to launch.

Before `Reset Everything` moves Application Support, `StateManager` explicitly closes and releases
its cached `ProjectDatabase`. That orders the SQLite checkpoint and releases the `-wal`/`-shm`
vnodes before the directory changes names; relying on process exit after the move leaves an open
connection targeting stale paths and is an SQLite API violation. A later access can reopen the
database, which keeps a failed reset recoverable while the normal successful path exits without
saving.

The relaunch itself is prepared before the reset's first mutation. `/bin/sh` starts with a private
pipe as standard input and waits for one commit line; a thrown Keychain, database, preferences or
filesystem operation closes that pipe without a line and terminates the helper. Only a successful
reset signals it, stamps the launch as intentional and exits. This makes “can the helper start?” a
precondition rather than a best-effort epilogue after state has already moved.

The reset is `ConfirmationPrompt.resetAppData`, on the `.alwaysAsks(.irreversible)` branch. Not
strictly true — the state is kept — but nothing *in the app* brings it back, and Return belongs on
Cancel for a button that restarts the app under you.

`Reset Everything` also stops Remote Access and deletes the paired-owner Keychain item before the
file reset. That is the one intentionally non-recoverable piece: backing up live bearer tokens as
plain files would turn the reset folder into a credential export. A settings-only reset keeps
pairings; a full reset is explicit authority to delete even a corrupt Keychain item that normal
fail-closed revocation refuses to overwrite.

## Custom theme assets

`AppThemeStore` keeps the small Codable theme document in `PreferenceStore`; image bytes live in
`~/Library/Application Support/Threading/ThemeAssets/<theme-id>/`. The document names fixed local
slots rather than absolute paths. `ThemeAssetStore` normalizes all inputs through the shared
ImageIO gate, owns the per-theme folder, copies it when a custom theme is duplicated, and removes
it when the theme is deleted. Reset Everything already moves the enclosing Application Support
directory aside, so these files receive the same recoverable reset as projects and baselines.

Classic `.wsz` import follows that existing ownership rule. Only the validated TITLEBAR image is
stored as `classic-titlebar.png`; the selected archive itself is not retained. The corresponding
`chrome.titleBar.classicSkin.titleBarAsset` value therefore moves with custom-theme JSON backups
without pretending the bytes are in the preferences domain. A document whose file is absent is
still valid and draws the stock clean-room Classic Player band.

## Visual baselines

`BrowserBaselineStore` is the app's second durable bundle store, under
`~/Library/Application Support/Threading/BrowserBaselines/`. It is worth reading beside the SQLite
store because it takes the same posture with different machinery, and because it is the first place
that had to distinguish three failure states rather than two.

**Missing, corrupt, and newer are three different answers.** A record whose `record.json` will not
decode is corrupt and is quarantined. A record whose `schema_version` is *higher* than this build's
is not corrupt at all — it is from a later Threading, and quarantining it would mean a downgrade
silently confiscated a colleague's approved baselines. It is left exactly as found, excluded from the
list, and counted, so the UI can say how many this build cannot read. Absent is simply absent.

**Quarantine failing is not a logging opportunity.** If the damaged directory cannot be moved aside,
`isWriteBlocked` goes true and every write refuses. Continuing would mean writing beside data the
store has just proven it cannot manage, and the one outcome that cannot be undone is destroying
something nobody has looked at yet.

**Validation re-reads.** A revision is written into a sibling `staging-<uuid>` directory, then read
back, re-hashed and re-measured *from disk* before the directory is moved into place. A short write, a
full disk and a truncated PNG all look fine from the caller's side; the failure they cause arrives
weeks later as a baseline that will not decode.

**Replacement is additive.** Approval writes a new revision and moves a pointer; the revision it
replaced keeps its bytes. Only revisions past the per-baseline cap are removed, never the active one,
and never before the record naming the new active revision is on disk.

**Quotas refuse rather than evict.** Every dimension is bounded — image bytes, attribution bytes,
baselines per project, revisions per baseline, project bytes — and exceeding a durable one is a typed,
visible error. A ring that quietly dropped the oldest approved baseline would make a user's claim
about what correct looks like expire without anyone deciding it should.

**Lifecycle is by project.** Deleting a session leaves the library alone; removing a project takes its
baselines, and the removal confirmation says so. Reset Everything already moves the whole support
directory aside recoverably, so no separate handling is needed.
