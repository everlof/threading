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

**Schema version 5 preserves control-authority tenures.** Version 4 introduced `control_grant`,
`supervision` and `supervision_event` as normalized records beside the project graph because their
identities, indexes and lifetimes differ from a session payload. Grants index the actor and
revocation time while keeping the full bounded `ControlGrant` as JSON. One supervision row is one
manager-child tenure: closing it changes its state rather than erasing its history, and adopting
the same child later creates a new row and event stream. The database permits any number of closed
tenures but uses a partial unique index on active rows to enforce that a child has at most one
current manager. The version-5 table rebuild copies both supervision rows and their events before
removing the old foreign-keyed tables, so migration cannot cascade-delete the audit stream.
Every relationship remains foreign keyed with `ON DELETE CASCADE`, so deleting either session
cannot leave usable authority or an orphaned audit stream. Event insertion and pruning to
`SupervisionDefaults.maximumEvents` happen in one transaction.

SQLite writes are **per row, in one transaction**, and `ProjectStore` has both exact-record and
graph-reconciliation routes. Session creation appends its one row at the project's final position;
removal deletes its row and shifts only later positions in that project. Generic single-session
updates, project settings, embedded-terminal updates, side-chat creation and coalesced
agent-title/turn metadata also retain the affected identifiers rather than converting a burst into
a delayed whole-graph save. A standalone terminal whose caller already knows its title is born with
that title in the same project-row commit; Update All and project scripts never append an unnamed
record and immediately rename it in a second transaction. Coalesced project/session payloads share
one transaction when their
timer expires; an immediate rename or other exact write removes only its own identity from that
set and never drains unrelated pending rows on the caller's main-actor stack. Project add/remove
changes one row plus the generation and later
positions; bulk conversation import inserts only the selected rows. Provider archive reconciliation
supplies every changed session row to one SQLite transaction: the values observed together either
all commit or all roll back, while unrelated archived history is not encoded or upserted. The
graph-reconciliation path remains for inputs that really are the complete graph—legacy migration,
recovery and authoritative test/maintenance setup. No ordinary interactive `ProjectStore` mutation
uses it. This is the actual gain over the document, and it retires
the rolling `projects.json.bak`, whose whole job was covering the window in which a full rewrite
could be interrupted. WAL is the other half: a read never blocks the writer, and `busy_timeout`
turns "another process has it" into a wait. That makes multiple writers *possible*, not permitted
— `SingleInstanceLock` still stands, and is a chosen concurrency model rather than a workaround.

**SQLite handles have one deterministic lifetime.** `SQLiteDatabase.Statement` finalizes in
`deinit` as well as after `run`: fluent binding can throw while the statement expression is still
being built, before `run` has installed its own `defer`, and that must not leave a native statement
holding the connection open. Both finalization and `SQLiteDatabase.close()` are idempotent, and a
failed database initializer closes the partly configured connection. Owners still close the
connection explicitly at storage boundaries—RAII is the backstop for an abandoned object, not the
ordering primitive for moving a database and its sidecars.

**A full disk pauses persistence; it does not condemn the database for the launch.** The SQLite
wrapper preserves the primary and extended result codes, so `SQLITE_FULL` is not collapsed into
the same string as corruption or an arbitrary I/O failure. `StateManager` records
`storageExhausted`, and `ProjectStore` rolls the attempted mutation back to its last committed
snapshot exactly as it does for every refused write. Recovery is explicit and evidence-based:
close the old connection, reopen the same store, require `PRAGMA quick_check` to report `ok`,
commit an insert-and-delete probe in `app_state`, and reload the complete authoritative graph.
Only all four steps restore writes in-process. A second `SQLITE_FULL` leaves the recoverable pause
standing; any other probe failure escalates to ordinary fail-closed recovery. The Start Session
path reports the refusal while retaining the brief, so its button and Command-Return route cannot
fail silently. Remote project mutations preserve the same typed cause as
`RemoteRESTErrorCode.storageExhausted`, allowing the iPhone to direct recovery to the Mac's disk
instead of reporting a generic persistence or route failure.

**A constraint refusal is local to the attempted operation.** SQLite applies a statement and its
surrounding store transaction atomically, so `SQLITE_CONSTRAINT` means the proposed state violated
a modeled invariant; it is not evidence that the database can no longer preserve unrelated data.
The caller still receives the failed write and rolls its in-memory mutation back, while
`StateManager` keeps persistence healthy. I/O, corruption and other unclassified failures still
enter fail-closed recovery, and `SQLITE_FULL` retains the recoverable pause described above.

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
`{"formatVersion":2,…,"tabs":[]}` that a pre-detached-windows build refused. What the
all-or-nothing rule protected is protected one row at a time — `StateManager` reports the row to
its feature as absent so the pane rebuilds, and refuses every write to it for the rest of the
launch, so the bytes are still there for the build that can read them.

That validation is **lazy at the feature boundary**, not cosmetic laziness. Startup scans only
the auxiliary `session_id` columns. The first panel/attachment read decodes that session's row;
more importantly, a first write that arrives before any read also fetches and validates the
existing row before replacing it. Successful validation is cached for the open database. A future
or corrupt payload joins the unreadable set and the write is refused. This removed full decoding
of every saved panel and attachment list from launch without opening a data-loss race. A row whose
`session_id` is not an identifier remains the necessary eager exception: no feature can ask for it
by id later, so startup records `containsUnkeyedRows` and only skipping the table's prune can keep
it. The project and session rows stay all-or-nothing and eagerly decoded because those are the copy
of record.

**The attachment document's `formatVersion` is 3.** Version 3 adds the optional exact turn id and
the current/next/neither placement used by the collapsible attachment chronology. The version bump
prevents an older build from silently rewriting a row while discarding that grouping metadata.
Within a readable version the fields remain migration-safe: an older user attachment points to the
next turn, an older agent attachment points to the current turn, and an unknown future placement
falls back through that same origin rule.

Authoritative session rows remain eager, but their healthy decode is **bounded and batched**.
`ProjectDatabase` joins at most 256 stored JSON objects into one temporary array and invokes the
top-level `JSONDecoder` once for that group instead of constructing a parser for every row. Indexed
id, project, provider and activity metadata stays beside each payload and is checked after decode,
in database order. If a batch fails, the loader decodes only that bounded group individually to
name the exact corrupt row and then refuses the complete load as before. This is an amortization of
the same all-or-nothing validation contract, not lazy or partial project-state loading; the bound
also prevents a 50,000-session store from becoming one correspondingly large temporary document.

Agent execution evidence has different write and trust needs from mutable application state, so it
does not live in SQLite. [Execution Audit](execution-audit.md) keeps a bounded append-only,
SHA-256-linked JSONL chain per session under `ExecutionAudit/`. Its directory and files are
owner-only, rotation is reported as a verified suffix rather than a complete history, and deleting
a session or project synchronously removes all of that session's segments.

Per-turn Git attribution also lives beside rather than inside SQLite. `git-turn-checkpoints.json`
is a `RecoverableFileStore` document whose records connect a session and stable turn identity to
the app-owned before/after refs described in [Git Review](git.md#git-review). The transition is
written before each Git operation, so a crash leaves evidence that becomes `incomplete` on the
next launch rather than a plausible-looking older result. Corrupt metadata is quarantined under
the normal user-authored-store policy; ref names are schema-validated to Threading's namespace
before the document is accepted.

The metadata and Git refs form one ownership unit. Retention is bounded to 50 turns per session
and 1,000 globally. Garbage collection removes only the two exact validated app refs and removes
the metadata only after Git confirms that operation; if no checkout of the recorded repository is
available, the record remains as a retryable cleanup receipt. Archiving is reversible and keeps
the unit. Permanent session or project deletion starts collection while the checkout association
still exists, and Reset Everything receives its existing recoverable support-directory behavior
without claiming to rewrite arbitrary repositories. On a normal launch, reachable project
repositories are reconciled against the loaded document: unowned, well-formed refs inside the app
namespace are collected, closing the leak left by quarantined metadata or an interrupted cleanup.
Recovery launch and failed project-state load perform no such sweep because an empty catalog is not
evidence that every checkpoint is orphaned.

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
Change-request publication evidence is another intentionally small defaults-backed store.
`ChangeRequestReceiptStore` keeps at most 100 newest receipts under the versioned
`changeRequest.publishReceipts.v1` key. Its record is provider-neutral: repository, branch, URL,
action and `ChangeRequestCredentialSource`, not a GitHub token type or provider response. The
decoder accepts the original `credentialTier` key and maps its existing values before all new
writes use `credentialSource`; adding GitLab therefore does not erase or strand earlier GitHub
receipts. Managed-workspace publication also persists its richer provider-neutral receipt inside
the session model before local worktree disposal; see
[source-control.md](source-control.md) and [managed-workspaces.md](managed-workspaces.md).

A related ordering trap lives one layer up. `AppSettings`'s **`nonisolated static` readers go
straight to `UserDefaults.standard`**, while the seeded defaults were registered only in its
`init` — so a read that happened before anything touched `AppSettings.shared` saw an
unregistered key, and `bool(forKey:)` answers `false`, which for every seeded setting is the
*opposite* of its documented default. The sidebar's branch grouping is what showed it. The seeds
are registered by the readers themselves now; registration is idempotent, and an invariant that
depends on instantiation order is not an invariant.

### Typed application-setting descriptors

Persisted app preferences have two representations with different jobs. `AppSettingIdentity` is
the closed persisted identity set. Each identity is authored once as an
`AppSettingDescriptor<Value>` such as `githubAppClientID` or `remoteAccessEnabled`; `Value`
determines its stored property-list category, while typed absence/default, validation, and
encoding factories make assigning a value of the wrong Swift type a compile error. The
heterogeneous persisted registry repeats only references to those typed declarations.
`AppSettingDefinition` is their derived type-erased projection, retained for catalogue
enumeration, migration audits, Settings navigation and search, and the read-only `list_settings`
wire result. Surface-only settings have no persisted Swift value and may be authored directly in
that erased projection.

The typed descriptor itself owns the stable defaults key, encoding, absence/default behavior,
validation or normalization, change-notification policy, presentations, and remote policy.
`AppSettings` reads and writes through descriptors, including
migrations with notification deliberately suppressed during construction. Invalid production
writes fail closed without replacing the previous value or announcing a change; notably the
GitHub App client ID cannot bypass its declared 1,024-byte bound through the ordinary setter.
Recoverable Codable preferences keep their specialized durable store, then ask their descriptor
to apply the declared notification policy only after the save commits.

Dynamic string identity is admitted only at the authenticated-owner mutation boundary. The
`/api/settings/<identity>` route first requires a whole-host owner, then the application mutator
projects authorization from `remotePolicy` and dispatches the admitted stored value to the same
typed descriptor used locally. `.ownerMutable` therefore performs a validated descriptor write;
view-only shares, `.catalogueOnly`, `.hidden`, unknown identities, wrong value shapes, and
unrecognized enum values all fail closed. `remoteInputControlDefault` is owner-mutable because its
effect is read when the next share is created. The transport enabled/mode/fallback settings remain
catalogue-only: changing them requires `RemoteAccessCoordinator` lifecycle sequencing, so a raw
remote persistence write would be dishonest. Adding a persisted identity without a typed
definition, duplicating a key, or drifting a row anchor/order fails the catalogue audit.

Scratch `AppSettings` fixtures own their exact `UserDefaults` suite names and remove those
persistent domains in teardown. This does not disable construction-time migrations: it lets them
exercise their real writes while ensuring the resulting marker is removed. cfprefsd may write a
42-byte empty plist after the host exits; `scripts/test.sh` collects only those empty UUID-named
domains on the next safe sweep.

## Two Writers, and the Reconcile That Trusted There Was One

`save(_:)` reconciles rather than rewrites: upsert what is there, delete what has gone. That is
the right shape for the single writer `SingleInstanceLock` promises, and it is unsurvivable for a
second one — a stale snapshot's reconcile deletes rows it never knew existed, and `session`'s
`ON DELETE CASCADE` takes each project's chats with it. There was a second writer, and it cost a
user real projects.

**The hosted XCTest bundle was the second writer.** It runs inside the shipping app, so
`StateManager.shared` resolved the developer's own Application Support directory and
`ProjectStore.shared` opened their live `threading.db`. Twenty test classes mutate that singleton
— `SessionComposerRenderTests` alone calls `addProject` a dozen times — and every one of those
calls `save()`. The test host never acquires the lock that was supposed to prevent exactly this:
`applicationDidFinishLaunching` returns on `NSClassFromString("XCTestCase")` *before* the
`SingleInstanceLock.acquire()` whose own comment says a second instance "must never get far
enough to write". So a test run's snapshot, frozen at whenever its `ProjectStore.shared` first
loaded, deleted every project the user added afterwards. The diagnosis is not inferential: fixture
project rows for `/var/folders/…/T/sound-scope-…`, `theme-menu-…` and `threading-drawer-drag-…`
were recovered from the live database, and two `threading.db.corrupt-*` files hold four projects
that no longer exist anywhere.

Two changes, because either alone leaves the failure reachable.

- **`StateManager` redirects under a hosted test** (`isHostedTest`), to a scratch directory keyed
  by pid — per-process because concurrent agents run this suite on one machine, and two runs
  sharing a store would be the same race one directory further out. This is the fix; every other
  store that matters already had this guard, and the one holding the projects and chats did not.
  A killed run leaks a scratch directory into the OS temporary directory, which is deliberate:
  sweeping the siblings would let one run delete a live one's store.
- **The reconcile proves it is current before it prunes.** `app_state.storeGeneration` counts
  changes to *which* rows exist; `load` records it, and `save(_:)` re-reads it inside its own
  transaction and throws `ProjectDatabaseWriteError.staleGeneration` rather than deleting when it
  has moved. `removeSession` advances it too, being the other write that changes membership;
  `saveProject` and `saveSelectedSessionID` do not, because neither adds or removes a row and
  charging an expansion toggle for a counter write was the cost those paths exist to avoid.
  The transaction returns its candidate generation and the connection publishes that value only
  after `COMMIT`; a failed commit rolls back both the rows and the in-memory claim instead of
  poisoning every later write as stale.

A refusal is **not** `requireRecovery()`. Nothing is corrupt — the store is intact and this writer
is merely behind it — so quarantining would take a launch's writes away over a guard that already
did its job. `ProjectStore` sees the failed write, rolls back to its last persisted snapshot, and
the row the other writer added survives. Refusing costs one unsaved edit; pruning cost projects.

It needed no migration and no `user_version` bump: `app_state` is key/value, and a build without
the guard simply ignores the key. Living in the same transaction as the reconcile is what makes
the check meaningful — read it outside and another writer commits between the check and the
`DELETE`.

`HostedStoreTestCase` is the test-side half, and it fails loudly rather than quietly: its teardown
asserts `StateManager.sharedUsesHostedTestState` before erasing anything, so a build that undoes
the redirect fails the suite instead of deleting the developer's projects on the way past.
`HostedStoreIsolationTests` reproduces the loss directly — two connections, one adds a project,
the stale one's reconcile must throw and leave that project standing.

The main-window test composition helper is intentionally part of `HostedStoreTestCase`, not a
general `XCTestCase` extension. Its controller receives the redirected shared hosted-test graph;
those services are not independently constructed. The helper separately owns each UUID-scoped
diagnostics directory until teardown releases the controller, environment, and `EventLog`, then
removes only that exact directory.

### 2026-08-15 — The same race, one domain further out

`PreferenceStore` redirects a hosted test away from `UserDefaults.standard`, which answers "not
the user's preferences". It did not answer "not another test host's", because the scratch suite
was one constant name — `codes.threading.hosted-tests` — for every process. The store above was
made per-pid for precisely the reason this one was not, and several agents running the suite at
once is this repository's ordinary working state, so two `xcodebuild test` runs shared a
preferences domain and read each other's recorded choices.

**It does not present as shared state; it presents as a haunting.** A test applies Cyberpunk,
reads the choice back through the app's own code, and gets Claymorphism. A recovery test that
stored `threading` reads `ext.com.example.pack.storm` — an id belonging to a *contributed* theme
that no test in that process ever installed. Six cases failed on one run and a different six on
the next; each passed alone, passed on a re-run, and bisected to a different neighbour every
time, because the interfering write was never in the process being bisected. The tell, when the
state was finally printed rather than inferred, was a stored theme id (`platinum-9`) that
appeared in a run whose own tests had never named it.

The suite is now named `codes.threading.hosted-tests.<pid>`. It stays *named* rather than
volatile for the original reason — `restore()`'s tests read back through the app's own paths what
they wrote through them — and the pid is what stops that name from being a rendezvous. It also
ends the cross-run persistence `themes.md` records as a hazard for `FollowsAppThemeTests`: a
default written by one run no longer outlives it.

`scripts/test.sh` collects the domains afterwards, by **liveness rather than by its own pid**:
cfprefsd flushes after the process it belongs to is gone, so a run deleting only its own file
would race its own write. A domain whose pid names no live process cannot be in use, and whatever
a run leaves behind the next one collects — the same shape as the empty-UUID-plist sweep beside
it, and for the same reason.

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
it, Codex falls back to the PTY quiet heuristic. The old hook-trust bypass is carried too only
when hook installation remains enabled: both were separate explicit choices before the rename, and current values win
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
instances are possible rather than impossible. The lock file also carries an owner card and has a
heartbeat beside it now, and a loser can end an owner that has stopped answering rather than only
quitting — see [`crash-recovery.md`](crash-recovery.md), including why a launch that took the lock
over reads the killed owner's marker as an unclean exit and why that is intended. Removing the file from a process that never wrote
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

New-session launch choices have a different commit boundary. The provider becomes
`AppSettings.defaultAgentKind`, and model/reasoning becomes
`AccountPreference.newSessionRunChoice` for the provider-qualified login, only after the
composer's delegate says it created the session (or a scheduled session was durably reserved).
A refused or abandoned form writes neither. The provider value uses `PreferenceStore` for the
shared app instance: in production that is the existing standard-defaults key; in a hosted test
it is the per-process scratch suite, so a render exercising OpenCode cannot change what the
developer's next real composer opens on. Injected `AppSettings` instances keep using their
injected defaults for the same key.

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
viewport.

**Position-only records are bounded to the 250 most recent, on the host as well as the clients.**
The rule was written for the companion archives and not applied here, and the omission is a typing
latency bug rather than a disk one: every mutation rewrites, re-reads and re-verifies the whole
file, and a draft and an annotation note are both written per keystroke. Nothing else in the app
ever deletes a reading position, so one is kept for every session that has ever been scrolled —
on a real machine the file reached 7,163 records and 2.2 MB, of which 7,159 were positions for
sessions that no longer existed, and one keystroke in a composer or an annotation note cost 47 ms.
Bounded, the same keystroke costs about 2 ms. A record holding an unsent draft, staged context or
an annotation document is never pruned; `SessionContinuityState.hasUserContent` is the line, and
the prune runs on load as well as on commit so a file that grew before the bound existed becomes
small at the next mutation rather than paying for one whole-file write at every launch. Editable image annotation documents live here too: normalized marks, stable asset
aliases, source custody, revision number, the stable composer-context id, and the last flattened
revision shared. They are written on every edit because the inspector window is only one view of
that work; closing it is not a persistence boundary and never implies publication. An unreadable
file follows `RecoverableFileStore` quarantine rather than being replaced silently.

The companion clients use the same contract with a wider key. iOS stores a versioned archive in
its own `UserDefaults`; the dependency-free browser stores one in same-origin `localStorage`.
Both length-prefix the paired host identity before the session id so ids cannot collide, persist
the last host/session route, keep Native and terminal drafts distinct, and remember the iPhone's
Direct/Compose preference for each terminal. The route's own URL is deliberately absent from that
key: every advertised address is a route to one paired host. Records containing an unsent draft or
an explicit terminal input choice are never pruned automatically; position-only records are
bounded to the 250 most recent. The iOS archive is also capped at 1 MiB and validates state count,
identity, viewport and aggregate draft bytes before decode is accepted and before encode is
attempted. Every mutation is made against a candidate archive, and that candidate becomes visible
only after the `UserDefaults` replacement reads back identically; a persistence refusal cannot
leave the running composer ahead of its durable draft. The device-local terminal-keyboard archive
follows the same candidate-first, bounded rule. No continuity archive is synchronized across
clients, because merging partial human input, moving another person's viewport or inheriting their
input preference would turn private continuity into collaboration state.

The iPhone terminal Compose editor writes through its binding setter, in the native edit callback.
SwiftUI `onChange` is not a persistence boundary: Back or a Direct/Compose switch can unmount the
view before the next render transaction delivers it. The same setter clears the durable draft
only after acceptance of the exact submitted text; restoring a draft does not write it again.
`TerminalComposeContinuityTests` edits the shipping editor inside a navigation controller, pops
it in the same turn, reloads the archive, and remounts the composer. That sequence loses both
the saved and visible text with the deferred `onChange` writer.

The iPhone's last resolved Mac app theme is a separate optional cache, not another field in that
continuity archive. `MobileThemeCacheStore` keeps at most 64 complete `RemoteThemeDTO` records,
scoped to the paired Mac, under a 256 KiB archive ceiling. A candidate is validated, written, and
read back before it becomes visible; corrupt bytes are quarantined, and a future version is left
untouched with writes disabled. `RemoteAppModel` consults it only while live `/api/me` state is
absent and records every later authoritative or local-preview theme replacement. Keeping this
derived appearance state separate means a malformed theme can never make an unsent draft or saved
viewport unreadable. The normal scale is 1–5 Macs: a palette read checks at most the stable and
pairing identities against the hard 64-record ceiling, and a write occurs only when the resolved
theme actually changes, never on a session or terminal hot callback. See
[`themes.md`](themes.md#2026-08-30--the-iphone-keeps-the-last-resolved-mac-theme-through-reconnect).

The iPhone's project disclosures are independent scalar preferences in
`MobileProjectDisclosureStore`, under `threading.mobile.project-collapsed.v1.*`. Each key hashes
a length-framed pairing ID and stable project ID (name fallback for older hosts). Missing values
mean expanded; both explicit states survive navigation, catalogue replacement and relaunch. A
rename preserves the choice when a project ID is available. Unknown scalar values remain untouched
and refuse writes. One toggle writes and verifies one Boolean; no catalogue or aggregate preference
archive is encoded. These are local navigation choices, not Mac project state or chat archives.

The iPhone dashboard's last-good catalogue is a second separate optional cache. It is keyed by
the exact pairing id rather than the Mac's stable host id because `/api/me` is capability-filtered:
two memberships on one Mac may expose different rows. The snapshot keeps only list identity and
organization metadata. It deliberately drops activity, availability, wake state, sharing,
account handles, launch choices and theme payloads, so a disconnected list cannot claim a live
right or status. `MobileDashboardCacheStore` decodes, validates, projects and encodes on its actor;
keeps at most eight pairings under a 4 MiB archive ceiling and explicit row/string limits; evicts
least-recent records under aggregate pressure; quarantines corrupt bytes; and leaves a future
version untouched with writes disabled during ordinary operation. A security purge that cannot
rewrite an incompatible archive deletes the whole optional cache, including unreadable recovery
copies that cannot be filtered by pairing. A live `/api/me` replaces the
cached catalogue in one publication by stable ids. Forgetting the pairing, a known share
expiration, or an authenticated 401/403 removes the cache. Ordinary route failure retains it.
Cached navigation must rejoin the
host refresh single-flight and resolve the id in a live catalogue before resume, attachment, socket
or mutation work begins.

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
the stored provider transcript path. Progress updates are coalesced before atomic writes. Snapshot
projection uses authoritative id/alias and transcript-path indexes, so a missing parent id does not
scan every child once per row. Routine encode/write work is serialized on a utility queue; an
explicit flush or app quit drains earlier writes and synchronously commits the newest snapshot.
Renderer teardown only queues its final state, so switching surfaces does not wait on a multi-MB
atomic write.

The same `SubagentSessionState` object is retained by `AgentRuntime` across an in-app renderer
switch, preserving live details without a disk round-trip. A full app relaunch loads the compact
snapshot and changes unfinished children to Stopped: persistence proves they existed, not that
their terminated process is still working. Deleting sessions calls `retainOnly`, which removes
both the runtime state and orphaned snapshot files. An unreadable snapshot is moved aside with
an `.unreadable-<uuid>` suffix before new state may be written; if quarantine itself fails,
writes for that session remain blocked rather than overwriting the only recoverable bytes.
Removing a session also invalidates its in-memory state before deleting the file. This matters
because token accounting finishes off-main: a late completion must not recreate a snapshot for
a session that no longer exists. The deletion itself shares the writer queue, after any already
accepted saves, so a stale write completes first and deletion wins rather than recreating the file.

## 2026-07-30 — Where it all is, and starting over

Two file locations hold Threading's ordinary state, and `AppDataLocations` is the only place that
says so: the **preferences domain** (the bundle identifier, `codes.threading`) and one directory,
`~/Library/Application Support/Threading`, which is `StateManager`'s root and therefore also the
store, the panel layouts and their cached PNGs, project icons, avatars, usage history,
icon-research records and the instance lock. Settings ▸ **Advanced** shows both and reveals them,
because "where is my data" is a question answered with a path to copy rather than a sentence.

**One subdirectory of that root is owner-only, and is a secret rather than state.**
`Threading/bridge/` is `0700` and holds two things a hook needs to find its way back to the app:
`mcp.sock`, the MCP server's unix rendezvous, and `session-tokens.json` (`0600`), the durable
per-session MCP tokens. The token is what guards a session's endpoint, so the directory's
permissions — not the endpoint's — are the boundary; see
[`mcp-and-display.md`](mcp-and-display.md). It is a plain file rather than a Keychain item
because it is read from the MCP queue on every hook and every tool call, and because losing it
costs a launch's routing rather than an account. An unreadable file is quarantined as
`.unreadable-<uuid>` and the launch mints fresh tokens; if the quarantine itself fails, writes
are refused for the rest of the launch rather than destroying the only copy. `MCPBridgeLocation`
resolves the directory — and the per-session `mcp/` and `settings/` files beside it — through
`StateManager`'s hosted-test redirect, so a test bundle hosted in the shipping app writes none of
this into the developer's own Application Support.

**`Threading/pty/` is the second owner-only subdirectory, and a deliberate sibling of the first.**
It is `0700` for the same argument — a unix socket inside it is reachable only by this user's
processes, and the directory's permissions are the boundary, not the endpoint's — and it holds
`ptyd.sock`, the `threading-ptyd` rendezvous, plus the daemon's own `sessions.jsonl` and its dated
journal. `PTYHostLocation` resolves all of it through the same hosted-test redirect, with a
sharper reason than tidiness: a test bundle runs inside the shipping app, so without the redirect
a test that started a daemon would bind the socket the developer's running app is listening on and
the two would fight over the same PTY children. Sibling rather than room-mate because the two
directories are owned by processes with different lifetimes, and a daemon that could write
`session-tokens.json` would be a daemon holding an authorization — which is precisely what the
daemon's safety argument says it never does. The **app only resolves paths and creates the
directory**; unlinking a stale socket and binding a new one belong to the daemon, since it is the
only process that may be listening there. The journal is in `pty/` and never in `Logs/`, because
`EventLog` prunes any `.jsonl` in that directory past the retention window and because its
descriptor is `O_APPEND` exactly on account of more than one process writing it — an interleaving
that has already cost one day's journal 23 unparseable lines. The app reads a bounded tail of the
daemon's journal through a `journalTail` frame rather than sharing the file. See
[`pty-host.md`](pty-host.md).

**`Threading/bin/` is the third subdirectory, and the one that is deliberately not a boundary.**
It holds one symlink per public command-line tool — today `threading-ptyd` — each pointing into
the running bundle's `Contents/Helpers`. It is `0755` rather than `0700` on purpose: unlike
`bridge/` and `pty/`, nothing here is a secret, every entry names a file inside a signed
application bundle that anyone who can read `/Applications` can already read, and calling it a
boundary would be claiming a protection it does not provide.

**The indirection is the whole feature.** A user installs `~/.local/bin/threading-ptyd` pointing
at the shim, never into the bundle, because the bundle moves: `scripts/autoinstall.sh` replaces
`/Applications/Threading.app` wholesale on every commit to master and a Debug build runs from a
DerivedData path that is different again. A link into `Contents/Helpers` would break the first
time either happened, and would break *silently* — `command -v` still finds the name and the
exec is what fails. `ThreadingCommandLineTools.refresh` rewrites this directory at every launch
to name the bundle that is actually running, so the user-facing link is written once and never
has to be written again.

The refresh is idempotent and narrow. A link already pointing where it should is left untouched,
so an ordinary launch is one `readlink` per tool and no writes, and only a launch that actually
moved something journals a line. A wrong link is replaced with `symlink(2)` into a uniquely named
neighbour followed by `rename(2)`, so the name never resolves to nothing in between. Nothing that
is not ours is touched: a name a public tool claims that holds a regular file is reported and
left, and an entry that is not one of the public tools is removed only when it is a symlink into
some bundle's `Contents/Helpers` under its own name, which is the shape the refresh writes and
nothing else does. Resolved through `StateManager`'s hosted-test redirect for the reason above
one paragraph: a hosted test would otherwise repoint the developer's own shims at the test host.
`~/.local/bin` itself is the user's, created if missing and never otherwise written to, and no
shell profile is ever edited — the Advanced row shows the line to add and stops there.

**The daemon's launchd registration adds nothing to this directory, and that is deliberate.** What
records that the agent is registered is launchd's own Background Task Management store and the
Login Items row, both keyed by the label `codes.threading.ptyd` and neither of them Threading's to
write; the app reads the state back through `SMAppService.status` rather than keeping a copy that
could disagree with it. The plist the registration reads is a **sealed resource inside the app
bundle** (`Contents/Library/LaunchAgents/codes.threading.ptyd.plist`), which is also why the
daemon derives its production paths from a `--default-locations` flag instead of having them
written into a per-user plist: a file inside a signed bundle is one copy shared by every account
and unwritable at runtime. So the registration is the second piece of this app's state living
outside the usual containers, beside the extension helpers' quarantine flags — see
[`releasing.md`](releasing.md#what-remains-open).

Security capabilities are the deliberate third category. Native owner-device and guest-share
records, including their 256-bit bearers, each live in one versioned generic-password item with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; the paired iPhone keeps its side in its own
Keychain. Both Mac stores use the data-protection Keychain when the signed build can access it,
under the same shared probe as the browser vault below. An ad-hoc build falls back to the login
Keychain and Settings states that weaker boundary rather than claiming the Release guarantee.

The iPhone defers pairing reads until protected data is available. Notification-only background
launches leave the pairing inventory unresolved, rather than treating locked Keychain storage as
an empty list. Unlock, initial foreground, foreground refresh and explicit Retry share one
asynchronous read; decoding stays off-main. Only a validated read (including a genuinely missing
item) enables writes. Failed reads preserve the selected Mac, widget association and credential
bytes; a relock during the read discards its publication and keeps writes disabled. Corrupt or
unsupported data remains unavailable and cannot be replaced by a pairing attempt. Healthy
foregrounds do not reread the store. One latest notification/widget navigation intent waits for
restoration; duplicate notification callbacks retain their existing deduplication contract. The
recovery screen is host-owned credential custody UI.

The hosted-service record (Hosted Direct's account session and host credential) is its own
Keychain item, and only a development build opens it. A release, beta or nightly build does not
offer Hosted Direct, so its hosted controller uses an in-memory store and never reads the record a
development build left in the same Keychain (`BuildChannel.offersHostedDirect`).

APNs registrations use a third, separate versioned Keychain item under the same storage policy.
It contains only device-bound delivery metadata — share id, device id, APNs token, environment,
and enabled/sounding kinds — never a bearer or authorization. On every Remote Access start the
complete record set is rebound to the current owner-device and accepted-member stores; expired,
revoked, and wrong-device records stay inert and are pruned. Registration persists a validated
candidate before making it live, while revocation commits to the authority store first and then
drops live delivery even if this secondary cleanup fails. A corrupt notification item therefore
fails notification registration closed without disabling pairing. Reset Everything names and
deletes it explicitly. Load, write, prune, revoke-cleanup, and reset-delete failures enter the
share-safe remote diagnostic journal with only a fixed stage and reason. The store is bounded to
288 records and 1 MiB: at expected cardinality it
contains 1–5 records. Persistence scans are O(total) only at registration, revocation, or Remote
Access startup. Notification fan-out is O(active subscriptions), bounded by the same 288-record
ceiling, and neither path runs on a session or terminal hot callback.

The move from the old login-Keychain items is validation-first. With no protected item, a valid
legacy envelope is written to the protected Keychain before the obsolete item is removed; corrupt
or future-version data remains untouched and fails closed. If neither item exists, an empty
versioned protected envelope is written once. That sentinel makes the protected store
authoritative immediately, so a login-Keychain item planted later by the agent's shell is ignored
and removed rather than imported. Once a protected item exists every read and write ignores the
legacy item for authority; the protected envelope is validated before legacy cleanup, and cleanup
is retried but cannot make an already committed protected write appear to have failed to the live
registry. Reset Everything attempts both locations explicitly.

A decode or write failure is fail-closed: the app neither overwrites an unreadable item nor issues
a credential it cannot persist. Turning Remote Access off clears runtime authority but does not
unpair devices or revoke shares. Named revocation writes Keychain first, then drops live authority
and sockets, so a failed revoke cannot appear successful and return after restart.

The browser's **test credentials** are another store in that third category, and one whose
placement is a decision rather than a default. `BrowserCredentialStore` writes generic-password
items under `codes.threading.browser.credential`, using the shared `KeychainStoragePolicy` to
prefer `kSecUseDataProtectionKeychain` —
which puts them out of reach of `security add-generic-password` and `security
delete-generic-password`, since the CLI cannot address that keychain at all and this app launches
agents with an unrestricted shell. That keychain needs an entitlement an ad-hoc-signed build does
not have, so the store **probes once and falls back** to the login keychain, and reports which one
it got through `isShellReachable` rather than letting a Debug build claim a Release build's
guarantee. It is deliberately separate from `KeychainManager`, which keeps
API keys in the login keychain: moving those to share one implementation would orphan every key
already saved. Because none of these stores lives under Application Support, **Reset Everything
deletes each explicitly**; without that, a reset would move the app's directories aside while
leaving every stored credential behind, having told the user it removed the app's state. Under a
hosted test bundle the browser service name redirects to a scratch service, for the same reason
`PreferenceStore` redirects its suite; the remote migration tests instead inject an in-memory
Security adapter and never touch the developer's Keychain.

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

## 2026-08-14 — The scratchpad lives outside both, on purpose

A scratchpad chat belongs to no project, but an agent still has to be launched *somewhere*, and
`Project` is validated at decode as an absolute folder path with a non-empty name. So the
scratchpad is a real folder and a real `Project` row; what is decided here is which folder.

**Not Application Support**, which is the answer the rest of this file would predict and the one
that is wrong. A managed worktree lives there (`ManagedWorkspaces/<session-uuid>`) and is right to,
because it is reproducible from a real checkout: Reset Everything moving it aside costs nothing but
disk. A scratchpad is reproducible from nothing — it is the only copy of prose the user wrote. The
reset does not delete, but the app comes back "as if newly installed" with those notes sitting in
`Threading Resets/<timestamp>/`, which nobody looking for their notes will ever open. Application
Support is also hidden in Finder, excluded from Spotlight, and an awkward path to `cd` into, and
this is a folder whose whole point is that you can also reach it from outside the app.

**Not `~/Documents` or `~/Desktop`.** TCC attributes a supervised child's file access to the app
that spawned it (see [`permissions.md`](permissions.md)), so the agent's first write would raise
*Threading's* Documents prompt — spending a permission dialog on a user's first scratchpad message,
before they have any idea what the feature is. Those are also the two folders iCloud's "Desktop &
Documents" syncs, and `git init` inside a synced folder is a known corruption and performance
hazard.

**`~/Threading/Scratchpad`**, therefore: not TCC-protected, not iCloud-synced, Spotlight-indexed,
Time Machine'd, and reachable from a terminal. The property that earns it over an exclusion list is
that it takes the scratchpad out of the reset's blast radius **by construction** — there is no
"except this directory" line in `AppDataReset` for someone to delete in two years, because the
directory was never inside it. A container (`~/Threading/`) rather than `~/Threading Scratchpad/`
so the path has no space in it and anything else the app ever has to keep somewhere reachable has a
name already.

`ScratchpadWorkspace` owns all of it. Three things it does that are decisions rather than detail:

- **The override goes through `PreferenceStore`, not `AppSettings`.** It records a *choice*, and
  the hosted test bundle is the app: a test writing it to `.standard` would repoint the developer's
  real scratchpad at a fixture directory that teardown then deletes. This is the same rule the
  theme selection is under.
- **The directory is required; the repository is not.** `/usr/bin/git` is the Command Line Tools
  shim, so on a Mac without them every git call fails and pops Apple's installer. Provisioning
  therefore throws only when the *folder* cannot be made, and logs-and-continues on git. A
  scratchpad without history is still a scratchpad. The same tolerance covers a missing
  `user.email`: the seeded README and `.gitignore` simply stay untracked, where Git Review shows
  them, which is the honest picture. Nothing here passes `-c user.name` — a commit in the user's
  own repository is made as the user or not at all.
- **`git init` names no branch.** `--initial-branch` would override whatever the user set
  `init.defaultBranch` to, in the one repository that is entirely theirs.

Only the first provisioning commits. After that the working tree is the user's business, and an app
committing on their behalf would be rewriting a history it does not own. Seeding never overwrites:
a README the user edited is theirs.

The row is marked with `Project.isScratchpad` — **stored, not derived from the path** — because the
folder can move and the chats inside it have to survive that. `ProjectStore.ensureScratchpadProject`
is the only way in: it re-points an existing row when the path changed, adopts a folder the user had
already added by hand rather than making a duplicate row for the same path, and otherwise adds one.
There is at most one. `SidebarTreeBuilder` pins it above the checkouts and answers "no repository"
for it when grouping — not only so it never joins a repository heading, but so it never *causes*
one: a project added inside it shares its git identity, and two checkouts of one repository is
exactly what earns a heading. The pin is a partition rather than a `sorted(by:)`, because Swift's
sort is not stable and the order of the rows under it is the user's own arrangement.

The Settings row picks the folder to keep the scratchpad **in**, appending `Scratchpad` to it. An
open panel returns the directory the user selected, so choosing the home folder would otherwise make
the home folder the scratchpad — and the first thing this feature does to a scratchpad is `git init`
it. Relocation is a rename, never a copy-and-delete, and refuses an occupied destination rather than
merging into it.

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
