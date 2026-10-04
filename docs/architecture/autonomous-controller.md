# Autonomous host controller

Status: portable core, owner CLI, ptyd execution and execution-scoped CLI/MCP tools implemented.
The resident supervisor dispatches queued work and answered continuations on the execution host. Rindabox installs the tested controller as a private VPS user service. The Rindabox consumer now owns authenticated operations UI, SSH owner transport, a daily enqueue
source and local/PostgreSQL destinations. Native Threading exposes remote automation configuration and history through the owner protocol. Fixture execution needs no model
account or production data; live model execution is not yet verified.

## Product and ownership

Autonomous workers consume work and deliver results to configured destinations. A conversation
or real TUI is an execution/debugging surface, not the primary work model. The normal product
surface will show work, outputs, pending questions and failures. A question addressed to a person
or group outlives the execution that asked it. Only the dependent work waits; independent work
continues. Answers supply information, not execution or connector permissions.

`Packages/ThreadingController` compiles without AppKit, providers, networking or PTY transport.
`Targets/Controller` builds `threading-controller`, an experimental macOS/Linux owner CLI over
that core. The app imports its portable models; process ownership and storage remain on the execution
host. The owner CLI has an independent build. The separation earns a package because a Linux process cannot import the app.

The controller owns:

- stable worker identities and work deduplication;
- atomic claims, checkpoints and distinct execution identities;
- asynchronous questions, first-authorized-answer resolution and continuation eligibility;
- a durable delivery outbox and attempt-specific receipts;
- versioned worker memory with compare-and-swap writes;
- an ordered durable event journal and bounded cursor reads.

Deployment repositories own worker recipes, domain schemas, recipient/group mapping, business
APIs, destination adapters and provisioning. No deployment-specific data model belongs in this
package. The first consumer lives in the separate Rindabox repository.

## Current state machine

`queued -> running -> waiting -> queued -> running -> completed`

Each claim creates a new execution. `ask` commits a question, checkpoint, yielded execution and
waiting work in one SQLite transaction. It does not synchronously wait for a person. `answer`
atomically records the first authorized answer and requeues that work. When a launch exists,
claim also requires its previous process to be confirmed stopped. Continuation creates a
new execution and reads the saved checkpoint and answers. Old executions cannot checkpoint,
ask another question, or finish the new execution's work.

This slice permits one outstanding blocking question per work item, addressed to 1–32 people or
groups; one eligible person resolves it. Multiple approval quorums, nonblocking questions,
deadlines, question ownership/claims, escalation and live group-directory integration are not
implemented. A host must resolve `AnswerPrincipal` from trusted authentication and group
membership at answer time. It must never accept those fields as agent-authored authority.

`finish` means computation finished and a delivery was durably queued. It does not mean that an
email was sent or a database was updated. Destination names are opaque routing keys, not grants.
The trusted adapter must authorize the exact destination before starting an external call.

## External effects and recovery

`pending -> sending -> delivered`, or `sending -> uncertain`.

The adapter commits `beginDelivery` before its external call. Use the stable delivery ID as the
destination idempotency key where supported. Only that attempt can acknowledge its receipt.
After a connection loss or crash, a `sending` record is unresolved, not proof of success or
failure. It is never automatically retried. An adapter can mark it uncertain and reconcile the
destination: an existing result gets an acknowledgement; proven absence permits an explicit
return to pending. A timeout is not proof of absence. New attempts fence late old receipts.
This is not a promise of exactly-once effects at an arbitrary external system.

Running work likewise survives a controller restart as running. A runtime/operator first proves
its process stopped, records `interrupt`, then explicitly retries if appropriate. The CLI
`interrupt` command records a fact; it does not send a signal. There is no expiry-based automatic
reassignment while a previous execution might still be active. Runtime recovery requires
reconciliation with ptyd and actual provider receipts, not an invented process liveness
heuristic. Host reboot cannot restore old PTY processes.

## Executing work through ptyd

`Targets/Controller/Sources/ControllerRuntime` links the shared `ThreadingPTYClient`; the core's
Foundation/SQLite import boundary stays unchanged. Owner-created `ControllerLaunchSpec` supplies
an absolute socket, executable and working directory, exact argv/environment, recipients and
one destination. Work text never becomes executable configuration. A recipe is bounded to
32 KiB, 64 arguments and 128 environment entries. No parent environment is inherited. Reserved
`THREADING_` entries are supplied by the runtime, not the recipe.

Recipe `environment` values are plain text in every worker-policy and launch row, and so in
backups. A credential belongs in the recipe's `secrets` map instead (environment name → secret
name, at most 16, disjoint from `environment`): the name is stored, and the runtime resolves the
value from the owner-only `secret-set` file beside the database (the same mechanism and checks as
trigger sources) when it dispatches. Secrets are read before the spawn right is consumed, so a
missing one fails the dispatch and leaves the intent `prepared` for an explicit retry once the
owner stores it. No status, policy or launch projection prints environment values or secrets.

`launch-prepare WORKER_UUID RECIPE_JSON_FILE` claims work and saves launch intent in one
transaction. `launch-dispatch EXECUTION_UUID` connects, commits `prepared -> dispatching`, issues
the execution's private credential (only its SHA-256 digest is stored; see
[Agent tool broker](#agent-tool-broker)), then sends exactly one spawn. The PTY identity is the execution UUID;
replacement authority is never set. `spawned` records pid and kernel start time and changes the
launch to `running`. `launch WORKER_UUID RECIPE_JSON_FILE` composes these operations. Its process
can exit: ptyd owns the child, and tools use the host-local work store with no Mac dependency.

A failed connection before dispatch leaves a prepared intent that can be explicitly dispatched.
A lost spawn response leaves `dispatching`, which cannot be dispatched again. A definite "no
process started" answer — a spawn refusal other than `alreadyExists`, or ptyd's `spawnFailed`
error for a failed fork (which now names the spawn and its errno; on a connection carrying one
spawn it is unambiguous from an older daemon too) — records the launch stopped with a bounded
`failure`. A recipe fault (`executableUnavailable`, `unsupportedChannel`) interrupts unfinished
work; a host fault (`retiring`, `capacity`, a fork failure) returns it to the queue, because
nothing ran and nothing about the recipe is wrong. There is no timeout-based reassignment. `launches WORK_UUID` finds saved intents after a lost CLI
response. Status output omits the recipe's argv/environment and the execution credential.

`launch-status EXECUTION_UUID` reads ptyd's inventory without attaching to or resizing a terminal.
It reports `running`, `stopped` or `absent`. Stop evidence, strongest first: a retained ptyd
receipt (spawns set `retainReceipt`, so ptyd keeps each exit or loss durably, across restarts,
until the controller acknowledges it — see [pty-host.md](pty-host.md#exit-kill-and-release)); an
exited inventory entry; and the current daemon's `lost` report, which follows ptyd reclaiming the
orphaned process group. A loss is recorded as `failure {stage: host, reason: lost, incident}` and
interrupts the work; like an exit, it is never an automatic retry. Exit alone interrupts
unfinished work, even for exit zero, and never invents a result. A non-zero, signalled or early
exit records `failure {stage: exit}` and a 2 KiB output tail with control sequences removed and
every recipe argument/environment value (8+ characters) and every credential-shaped token (the
store no longer holds the credential's value, so it is recognised by form) redacted —
best effort, not a secret scanner, so it stays an owner-only diagnostic. After recording, the
controller acknowledges only receipts whose launch exists in its own store and is stopped.

An absent entry with no receipt or loss report leaves the durable launch unresolved: an older
ptyd retains exits for a bounded window only, and omission from inventory proves nothing. A pid
that differs from the recorded one is reported (`process_identity_mismatch`) and never recorded.
A live inventory after a lost spawn receipt may report `presence=running` with a still-
`dispatching` durable launch; this is observation, not a fabricated pid/start-time receipt.

`launch-stop EXECUTION_UUID` first records any existing stop evidence, otherwise attaches to that
exact identity, requests kill and waits for its exit receipt before recording stopped. Timeout
remains unresolved. `launch-confirm-stopped EXECUTION_UUID [EXPECTED_STATE]` is an owner-only
recovery assertion requiring independent evidence; it does not signal a process. The expected
state (`prepared`, `dispatching`, `running`) fences it against a launch that moved since the
owner looked; owner RPC requires it. `interrupt` is refused while the execution's launch is
unresolved — confirm the launch first, which interrupts it.
Answered work stays unclaimable while any prior launch is prepared, dispatching or running.
Other work remains eligible. The resident supervisor records available exit receipts before
launching continuations; manual users can do the same with `launch-status`. Provider grandchildren are subject to the
existing PTY process-group contract, not an OS workload/container boundary.

For intervention, the existing `threading-ptyd attach EXECUTION_UUID --socket PATH` observes the
real terminal; add `--input` deliberately to type. The autonomous controller discards PTY output
and never interprets ANSI output as work status. Its control inbox is capped at 64 frames/4 MiB;
each request has a bounded wait. Prefer noninteractive provider turns for unattended execution.

## Execution-scoped tools

The launched child receives the controller executable, the broker socket
(`THREADING_CONTROLLER_AGENT_SOCKET`), execution ID and private credential in environment
variables — never the store path (see [Agent tool broker](#agent-tool-broker)).
`threading-controller agent REQUEST_JSON_FILE` exposes a
single typed operation; `agent-mcp` exposes the same operations over newline-delimited stdio MCP:
`work_context`, `work_questions`, `work_messages`, `work_history`, `work_message_consumed`,
`work_checkpoint`, `work_ask`, `work_finish`, `memory_list`, `memory_get`, `memory_put`, `memory_delete`,
`knowledge_get`, `knowledge_put`. These adapters have no claim, answer, retry, stop, delivery acknowledgement, arbitrary
SQL or destination-selection tool. Question recipients and output destination come from the
immutable owner recipe. Memory derives its worker from the execution's work.

Admission, active-execution checks and mutation run inside one write transaction, using nested
savepoints to compose existing core operations. Terminal writes allow identical receipt retries
until the process is confirmed stopped; later memory writes and context reads require a current
running execution. A stopped launch revokes all tool calls. The credential never appears in
status/events and is stored only as a digest; private recipe/database files are still sensitive.
What this isolates depends on the Unix accounts: an agent running as the controller's own
account can still open the store with its shell, so the broker is then scoped routing only. Run
agents as their own Unix user ([below](#running-agents-as-another-unix-user)) when a shell agent
must not hold owner authority.

## Agent tool broker

The resident `supervise` serves agent tools on a Unix socket: `--agent-socket PATH` (absolute;
default `agent.sock` beside the store), created `0660` under the service's `0077` umask and then
widened, never the reverse. A leftover *socket* there is replaced (the supervisor lock makes this
the only listener); any other file there is refused, never deleted. While it listens, the store
holds an `agentBroker` record naming it (withdrawn on shutdown, only if it still names this
socket); `host` reports it as `agentSocket` only while a connect succeeds, and `--version` lists
`agent-broker`.

- **Wire.** One connection carries one request: a JSON line `{execution | mailbox, credential,
  request | transcript}` and one JSON line back, `{response}` or `{error}` with the store's own
  token (`forbidden`, `conflict`, `invalid_input: …`). The request decodes only as
  `ControllerAgentRequest` (the agent tools) or a provider transcript report; there is no owner
  vocabulary to reach, and an envelope naming both or neither caller is `forbidden`. Unknown keys
  are ignored, never interpreted.
- **Authority.** Exactly the operations the agent could perform with its credential before the
  broker existed: `agentRequest`, `mailboxRequest` (mail tools only) and `bindProviderTranscript`,
  each authenticated by the credential against the stored digest (constant-time). The peer's uid
  (`getpeereid`/`SO_PEERCRED`) is recorded, never trusted: the first request per execution and uid
  adds `launch.agent_peer` (text `peer uid N`, so it is in the work's history), a mailbox's adds
  `mail.agent_peer`, and refusals add `agent.broker_refused` (at most 30 a minute).
- **Bounds.** Requests 320 KiB, responses 4 MiB (larger answers `response_too_large`), 10 s per
  connection for read, operation and write together, at most 32 concurrent connections; a
  connection past that is answered `busy` at once and closed. The broker runs on its own accept
  thread and handler threads with its own store connection, so a silent, slow or oversized
  client holds one slot and never a supervisor tick (`test_controller_broker.py` holds 40 silent
  connections while the supervisor records an exit).
- **Clients.** With `THREADING_CONTROLLER_AGENT_SOCKET` set, `agent`, `agent-mcp` and
  `agent-notice` make one bounded connection per call and open no store, even if a store path is
  also present; without it they need `THREADING_CONTROLLER_DATABASE` (below), and with neither
  they refuse. The dispatcher drops a store path from the child environment when it uses the
  broker.
- **Without a resident supervisor.** A manual `launch`/`launch-dispatch` uses the advertised
  broker when it answers. Otherwise it refuses (`agent_broker_unavailable`) before anything is
  claimed or consumed, unless the owner sets `THREADING_CONTROLLER_LEGACY_AGENT_DATABASE=1`: the
  child then receives the store path and opens it itself, recorded as
  `launch.legacy_agent_database`. A one-shot `supervisor-tick` never reaches a running
  supervisor's broker: it takes the same exclusive lock as `supervise`, so it answers `conflict`
  while one runs. On its own it has no broker, so it dispatches only under the same opt-in and
  otherwise leaves the intent prepared with `agent_broker_unavailable`. That compatibility mode is honest only
  when agent and controller are one account that already trust each other; tests and stores
  without a supervisor use it.
- **Credentials at rest.** Execution and session-mailbox credentials are 244 random bits stored
  as `sha256:` digests. An execution's is issued at dispatch, after the spawn right is consumed;
  a session's when the owner asks for one at launch (`mail-credential`, which therefore issues
  rather than reads back). Opening an older store digests every plaintext credential once, in one
  transaction, recorded by a `storeMigration/credential-digest` record (no DDL); an agent holding
  the plaintext keeps working.

## Running agents as another Unix user

The broker is what lets agents run without the controller's file permissions. On Linux, with
`install-host.py` from the controller host bundle. The installer writes units and copies the bundle
into each account's home, nothing else: the accounts, the group, the shared directories, the
agent-binary copy and linger are manual steps, done as root before it runs.

1. Accounts: a controller user (say `threading`) and an agent user (`agent`), both members of a
   group shared for the two rendezvous (`threading-agents`). The agent user is in no other group
   of the controller's.
2. Store: the controller's state directory stays `0700` owned by the controller user — the CLI
   refuses any other. Secrets, the supervisor lock and the store live there. Nothing in it is
   group-readable.
3. Broker: a directory like `/srv/threading/broker`, owned `threading:threading-agents`, mode
   `2750` (setgid, so the socket takes the group). Install the controller half with
   `install-host.py BUNDLE --role controller --agent-socket /srv/threading/broker/agent.sock
   --agent-binary /opt/threading/threading-controller`, where the agent binary is a copy of the
   same controller every agent can execute (the service's own copy under its `0700` home is not).
   The installer refuses an `--agent-binary` that is not an absolute path to an existing
   executable and passes it through to the unit's `supervise --agent-binary`; making and
   upgrading the copy is the operator's.
4. ptyd: a directory like `/srv/threading/pty`, owned `agent:threading-agents`, mode `2750`.
   Install the daemon half as the agent user with `install-host.py BUNDLE --role ptyd
   --ptyd-socket /srv/threading/pty/ptyd.sock`: the unit runs `threading-ptyd --group-socket`
   (socket `0660`) under `UMask=0027`. Recipes name that socket as `socketPath`; their
   `directory` must be the agent user's.
5. Provider homes (`usage.accounts`) belong to the agent user. The usage collector reads
   transcripts under them as the controller user, so they must be group-readable: the unit's
   `0027` umask covers files the provider creates with default modes; add a default ACL
   (`setfacl -d -m g:threading-agents:rX`) where it does not. A provider that writes its
   transcripts `0600` explicitly cannot be collected this way and shows as a coverage gap, never
   a silent zero.

What this gives: an agent's shell cannot open, copy or replace the store, the secrets or the
lock; its tools still work through the broker with its own credential, and a credential taken
from another agent's environment is the only way to act as that execution (the agent user can
read its own processes' environments, so agents of one Unix user are not isolated from each
other). What it does not: the controller user can still connect to ptyd and run anything as the
agent user, by design. `test_controller_agent_user.py` (Linux, as root, run by
`scripts/test-controller.sh` in the controller-linux container) builds exactly this layout and
asserts the agent's `open` of the store fails while its tools, memory write and finish succeed
and the broker records its uid.

Mac remote chats with a host-local mailbox follow the same rule: when the host's `host` answer
lists `agent-broker` with an `agentSocket`, the session gets the socket instead of the store path
(`MailboxEnvironment`); an older host, or one with no supervisor answering, keeps the store path.

MCP supports initialization, ping and tools only, with no network listener. It negotiates the
2024-11-05 through 2025-11-25 versions, advertises no optional sampling/tasks capabilities, retains
exact integer/string request IDs, rejects extra tool arguments, and caps input lines at 256 KiB.
Question reads retain the core's cursor/byte bounds. A POSIX read returns available pipe bytes:
Foundation `read(upToCount:)` waited to fill a buffer in the real stdio test, deadlocking a client
that correctly waited for the first reply before writing again. The integration fixture pins
short/fragmented live-pipe requests and terminal-write fencing.

Protocol references: [MCP lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle),
[tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) and
[stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

## Resident supervision and worker policy

`worker-configure WORKER_UUID EXPECTED_REVISION MAX_CONCURRENT RECIPE_JSON_FILE` saves an
owner-authored recipe and a 1–8 process limit. Revision zero creates it. Creating or replacing
configuration leaves it paused; `worker-enable WORKER_UUID REVISION` and `worker-pause` change
admission with compare-and-swap revisions. Status omits recipe arguments and environment.
These are host-owned administration operations, with the stable worker as entity. No extension
or model tool can configure a recipe, enable work, widen grants or choose recovery policy.

`supervise [POLL_MILLISECONDS]` runs the host-local loop (default 2,000 ms, range 100–60,000).
A non-expiring OS file lock beside the database permits one resident supervisor. It is not a
time lease and its file is not unlinked on exit. SIGINT/SIGTERM stop future sweeps, allow the
bounded current operation to settle, and release the lock without killing ptyd-owned children.
Systemd deployment, resource budgets and which workers to enable belong to the deployment repo.
`supervisor-tick` runs one bounded pass for diagnosis, under the same lock, so it answers
`conflict` while `supervise` runs (stop the unit first); repeatedly invoking it is not a substitute
for the resident loop, which retains fairness cursors.

Each tick reads at most eight unresolved launches and eight worker policies, wraps its cursors,
and sends at most two new spawn attempts. One item never stops the loop: a failed observation,
cancellation, dispatch or policy admission becomes an issue (`observe_failed`, `workerIssues`,
…) and an in-memory backoff for that item (30 s doubling to 15 min), and the pass continues. A
busy store (`SQLITE_BUSY`/`LOCKED` past the 3 s busy timeout) is reported in `tickIssues` and
retried next pass without quarantine. Only a store the process can no longer trust or write —
corrupt, not a database, read-only, full, I/O failure, or migrated by a newer build — ends the
resident loop, so one held lock cannot exhaust a service manager's restart budget. A socket
that fails inventory, refuses to connect, or answers with a transient refusal is skipped for a
backoff (5 s doubling to 5 min): no prepared intent is dispatched to it and no new intent is
prepared against it (`host_unavailable`). Transcript-collection failures are reported in
`usageIssues` rather than swallowed. Inventory is shared once per socket in the page, with
at most eight concurrent bounded requests. One attempt is reserved for fresh work so repeated
connection failures on an old prepared intent cannot starve another worker. No transcript is
retained, no TUI is attached, and no external destination is invoked by the supervisor. Its JSON
reports contain counts, execution IDs and structural issue codes, never prompts or credentials;
idle passes emit nothing.

Admission and preparation share one SQLite write transaction. Per-worker limits count every
unresolved launch, including manual and uncertain launches. Automatic admission also has a
store-wide ceiling of 32 unresolved launches and a per-socket ceiling of 16, so a host whose
launches cannot be resolved holds at most its own share. Queued work that admission holds back
is reported as `held: [{workerID, reason}]` — `host_unavailable`, `global_capacity`,
`host_capacity`, `worker_capacity`, `quarantined` or a `worker-capacity` reason such as
`usageUnsettled` — whenever the set changes (every one-shot `supervisor-tick` prints it); an idle
worker with nothing queued is not a hold. `launch-occupancy` reports unresolved launches by host
and state with both limits. An explicit manual owner launch can exceed those
scheduling limits; it still contributes to the supervisor's occupied slots. `active-launches
[CURSOR]` inspects these records without exposing recipes. Failed work stays interrupted until
an owner explicitly retries it. Missing inventory, timeouts and daemon restarts never authorize
an automatic replacement. A definite recipe refusal pauses the matching policy revision so a
broken recipe cannot consume the entire queue; a newer owner revision is not overwritten. A
transient host refusal or fork failure requeues the work (`requeued`) and backs the host off
instead.

A supervised intent records the policy revision that prepared it. Restart can dispatch that
intent only while it is still prepared and the same revision remains enabled. A superseded or
paused prepared intent is atomically cancelled and its unfinished work requeued: no spawn was
sent. Once dispatch has begun, uncertainty must be reconciled. A manual `launch-prepare` remains
manual. Pausing a worker stops future admission; running processes retain their original scope
and can finish, ask or be explicitly stopped. An already committed dispatch is not recalled by
a later pause.

An argv element equal to `${THREADING_EXECUTION_ID}` is replaced with the stable execution UUID
at dispatch. No shell expansion or substitution of work text occurs. This lets a stored provider
recipe mint a new provider session per execution without reusing one configured session ID.
Embedded MCP environment placeholders remain the provider configuration's responsibility.

The supervisor also admits the host-owned recurring automations described below. It is not a
self-healing service. Retained receipts are bounded (256 per daemon, oldest evicted and
journalled), an older ptyd still applies its ordinary retention window, and a lost or replaced
state directory, or a ptyd that never comes back, leaves a launch unresolved for operator
reconciliation through the fenced owner-RPC repairs. History retention is the owner's
`prune` (below); backup scheduling, provider authentication,
remote identities and destination delivery are consumer adapters; Rindabox now implements an
owner/admin inbox and draft consumers. Production activation remains opt-in.

Worker/enqueue/ask/answer/finish have retry behavior that either returns the committed result or
refuses changed content. Claims and delivery starts deliberately refuse/reveal uncertainty on
lost responses; callers inspect durable state rather than blindly repeating side effects.

## Persistence and scaling

SQLite is on the execution host's local disk. One `ControllerStore` actor owns each connection;
multiple local CLI processes serialize mutation through `BEGIN IMMEDIATE`. WAL and FULL
synchronous commits preserve acknowledgements. No client opens a SQLite file over SSH or a
network filesystem. Each mutation and its journal entries commit together. Failed, corrupt or
future-schema stores are errors and are not recreated as empty. Corrupt stores are left in place
for explicit recovery, rather than automatically moving files under another running process.
Each migration step runs in its own `BEGIN IMMEDIATE` transaction that re-reads `user_version`,
applies only below its target and never writes a lower version, so concurrent opens of an old
store serialize and each backfill runs once. Every later write transaction re-reads the version
under its write lock and refuses (`unsupported_schema`) unless it is exactly this build's, so an
older process left running after a newer build migrated stops writing; a resident supervisor
exits on it. Reads outside a write transaction are not fenced.

Schema v6 stores small typed payload rows with indexes for kind, identity, parent, source key,
state and cursor. State indexes and payloads have one write owner. Reads decode only the requested
page; claims query the indexed queue. No partial read is written back as a complete catalogue.
Rows are retained until the owner runs `prune --before DATE [--after CURSOR]` (also over owner
RPC). It deletes `event` journal rows and task activity of completed or cancelled work older than
the cutoff, and drops the fields and evidence of older trigger source events while keeping each
one's row, (id, revision) dedupe key and admission receipts, so a redelivery still admits nothing
twice. Work, questions, deliveries, launches, usage receipts, automation runs, mail and memory are
never pruned, and the most recent day is refused (`prune_too_recent`). Journal sequences are
AUTOINCREMENT, so a consumer's event cursor stays valid across a prune. Each 100-row batch commits
on its own and one call examines at most 10,000 rows, returning `more` and a `next` cursor to
continue from. Backup scheduling remains a consumer adapter's policy.
Opening a v1/v2 store transactionally adds indexed launch ownership (`scope`) and the partial
active-launch index, backfilling ownership from the work record without rewriting payloads. An
orphaned launch fails migration; it is never treated as available capacity. Older binaries refuse
v5 rather than bypassing revision checks. No downgrade is supported. Claims use the ready-state
index and an indexed anti-join on unresolved launches. Supervisor scans explicitly use the partial
index so stopped history cannot turn an eight-result limit into an unbounded history walk.

Expected initial load: 10 workers, 100 active work items, 10,000 retained records; stress target
100 workers and 100,000 records. Each page is capped at 100 records (CLI uses 50) and 1 MiB of
encoded row content, stopping before loading the next row; its cursor retains every unread row.
SQLite also bounds individual encoded records at 1 MiB. Text fields are
32 KiB, names/keys/destinations 256 bytes, receipts 4 KiB, questions 32 recipients. Claims and
exact lookups use indexes; reading historical work is never required to claim a ready item.
CLI input reads at most 32 KiB + 1 and refuses FIFOs, device files, symlinks and invalid UTF-8.
The first tests exercise both row and aggregate-byte pagination. The opt-in fixture
`python3 scripts/tests/profile_controller.py /path/to/threading-controller 100000` manufactures
100,000 historical/queued records separately from timing actual CLI claims and 50-row reads.
The 2026-09-30 macOS Debug baseline used the ready-state index: five claims had median 24.84 ms,
max 214.97 ms; five page reads median 47.35 ms, max 149.06 ms, including process startup and store
open. Fixture manufacture took 2.99 s. These are initial measurements under concurrent builds,
not resident-service latency or UI evidence; measure that shipping path when it exists.
After adding the aggregate-byte bound, the same fixture gave claim median 79.18 ms/max 143.75 ms
and page median 19.99 ms/max 85.10 ms (manufacture 4.58 s). Both used the same ready index and
returned the same 50-row page. Concurrent build load makes these timing differences inconclusive;
the verified change is bounded retained bytes, with a regression test for escaped large records.
The runtime fixture adds ten answered items held by unresolved launches before the five eligible
items. At 100,000 work rows, both sides of the claim anti-join used `record_ready`, all ten held
items were skipped, and pages remained 50 rows. macOS Debug: claim median 297.41 ms/max 626.51 ms,
page median 142.30 ms/max 197.50 ms, manufacture 1.25 s, under concurrent Linux/app builds.
These process-startup timings do not establish a resident-service latency budget.
The supervisor's initial budget is 10 configured workers/32 active launches, with 100 workers and
100,000 retained launches as the stress case. `profile_controller_supervisor.py BINARY 100000`
compares five one-pass executions before and after manufacturing stopped history (0.81 s).
macOS Debug median/max: 15.08/20.20 ms before, 17.51/22.27 ms after, including CLI startup.
Both read the same single manual intent and paused policy; the active-index query was asserted.
This measures history independence, not model latency or an unhealthy host's timeout budget.

Worker memory is explicit text with revision history. Updates require the current revision,
including zero for initial creation. It is scoped by stable worker identity, independent of a
provider transcript. Every revision records host-attested provenance — `actor` (`owner` or
`agent`), the agent's `executionID`, and `at` — taken from the authenticated route, never from
model input; revisions written before provenance existed carry none. Shared knowledge (below)
records the same. Semantic search and provider context injection are not implemented. These
records are context, never a source of permission grants or system instructions.

Removing and forgetting are separate. `memory_delete` (agent, its own worker) and owner
`memory-delete` write a compare-and-swap **tombstone** revision: the entry leaves `memory_list`
and returns an empty body with state `deleted`, and its history stays reviewable. Owner
`memory-forget` (and `knowledge-forget`) additionally blanks the body of every stored revision
and leaves a `forgotten` tombstone. Both keep the revision, so a delayed write at revision zero
cannot recreate the entry; relearning is a new authorized write at the tombstone's revision. The
connection runs with `secure_delete=FAST` (replaced cells are zeroed inside pages already being
written), forgetting runs with full secure delete and then truncates the WAL, so the text leaves
the live database files. Earlier backups and provider transcripts are outside this store.

Quotas bound what a write may add: 1,000 active keys and 4 MiB of active body text per worker's
memory and per knowledge space. Usage is kept in one row updated in the writing transaction (a
store from before quotas is counted once, on its first write); a write that grows usage past a
limit fails with `memory_key_quota`/`memory_byte_quota` (or the `knowledge_` equivalents),
while reads and writes that shrink usage always succeed. Tombstones do not count, and the key
listing reads active rows through the state index, so deleted keys never make a page sparse.

## Authority and customization boundary

This CLI is deliberately host-only: it has the authority of its Unix account, just like an owner
opening the local database. It requires an existing owner-only database directory and creates
private files. The database leaf cannot be a symlink; parent paths are canonicalized because
macOS `/tmp` and `/var` themselves are symlinks. The owner can attest which person and current
groups an answer represents. This is attribution, not authentication of that person.

Do not expose the owner CLI as an unrestricted MCP tool or wrap it in a public HTTP endpoint. The
future service must derive actor identity, scopes and destination grants from authenticated
credentials and reuse/extract the existing [control-plane](control-plane.md) policy vocabulary.
No session grant is widened by adding this independent work store. Agents sharing one Unix
account are not isolated from one another; strong isolation requires separate OS boundaries.
Agents never need this CLI's authority: their tools go through the supervisor's broker, and on a
host that runs them as another Unix user they cannot open the store at all
([Running agents as another Unix user](#running-agents-as-another-unix-user)).

No UI or public extension component is added in this slice. Future presentation may customize
work/result content, but claim ownership, status truth, routing, identity, answer admission and
delivery approval remain host-owned. Remote UI must apply the snapshot/stream continuity and
stale-state rules in [status-integrity.md](status-integrity.md). The current cursor lists are
local owner reads, not an authenticated live catalogue protocol.

## Verification and next slices

Run `bash scripts/test-controller.sh /absolute/scratch/directory` on macOS or Linux with Swift 6,
SQLite development headers and Python 3. It tests durable restart/continuation, concurrent claims,
transaction rollback, idempotency conflicts, stale executions, delivery ambiguity, memory CAS,
corrupt/future stores and the real CLI's process/file boundaries. No model or external account is
needed. Rindabox's separate fixture workflow tests the consumer against this built executable.

Verified on 2026-09-30: 21 core tests, 7 real-CLI checks and 10 real-PTY/MCP/supervisor checks passed on macOS
arm64 and Ubuntu 24.04 arm64 (Swift 6.3.2, system SQLite). Rindabox's build and eight enabled
tests passed against the final macOS executable; two existing PostgreSQL tests skipped because
no test database was configured. The hosted worker completed question → answer → continuation →
draft delivery using a separate process for each execution, with the supervisor recording exits
and launching the continuation automatically. Architecture and Ansible syntax checks also passed. The
application's full Xcode suite, Linux x86_64/static distribution, live provider execution and
production destination access are not verified by this standalone gate.

The second slice adds 4 core launch/scope tests and 6 real ptyd integration checks for disconnect,
single dispatch, answer/process overlap, worker memory, a new continuation, exit without result,
spawn refusal, daemon restart and scoped MCP. Rindabox has a hosted fixture worker and a Claude
recipe with only the scoped MCP tools; its model login/live run remains unverified.

The supervisor adds five core checks for migration, cross-connection capacity, global capacity,
revision changes and manual ownership, plus four real-process checks for restart/continuation,
pause/child survival, refusal circuit breaking and fairness across unavailable hosts.

The general owner protocol, shared knowledge and indexed inbox/outbox reads are implemented below.
Native Threading remote automation UI is implemented; production deployment/model validation is consumer-owned.
Database writes, emails and application drafts are destination adapters with
their own authority and reconciliation contracts, implemented in their owning repositories.


## Shared context and operations transport

Schema v4 backfills question ownership and adds `unresolved_delivery`, a partial sequence index.
`open-questions WORKER` reads through `record_scope_state`; `pending-deliveries` reads only pending,
sending and uncertain rows through its partial index. Both default to eight rows/1 MiB, advance
past every examined result and never scan closed history. `question`, `work-deliveries` and
`launch-record` supply bounded owner projections for detail/control surfaces. The consumer must
authorize worker visibility before returning those records; this CLI is not a multi-user ACL.

Shared knowledge uses opaque space UUIDs and owner-managed per-worker grants (`none`, `read`,
`write`). Grants and content use compare-and-swap revisions. Scoped tools derive the worker from
the authenticated execution, recheck the current grant in the same transaction as use, preserve
immutable content history and record the actual execution ID and provenance. A running worker loses access on
its next call after revocation. No work text or shared content can issue grants. Existing
worker-local memory remains private to that worker's scoped tools. Shared knowledge is untrusted
context and may contain mistaken or malicious instructions; it is not host policy.

`owner-rpc` carries one command and up to 16 value/text arguments in at most 256 KiB of JSON on
stdin, returning one JSON response. It includes fenced recovery: `launch-confirm-stopped` (its
expected-state argument is mandatory over RPC), `interrupt`, `launch-dispatch` (a still-prepared
intent only) and `delivery-confirm-absent` (the named attempt only), plus `launch-occupancy`.
`version`, `--version` and `host` report `{protocol, schema, features[]}`; a client checks a
feature (`launch-repair`, `host-receipts`, `launch-failure`, `launch-occupancy`, `schema-fence`)
before relying on it. `capabilities` keeps its original string for installers that pinned it. Text arguments become private bounded host files and are
removed after the operation. Only a fixed set of bounded operations is available: it cannot
start a supervisor. Worker configuration accepts a bounded owner-authored recipe with the same
revision checks and paused-on-configure behavior as the local CLI. A consumer must construct
that recipe from trusted deployment configuration, never from an HTTP task or model output. It has **owner authority**, authenticated by
SSH/the Unix account, and is never an unauthenticated HTTP server. Rindabox's server invokes it
over pinned SSH, derives human identity from its authenticated session and holds current-role
locks through mutations. Rindabox owns that application-specific mapping, destination schemas
and PostgreSQL adapter. The generic core contains none of those business concepts.

Customization-surface gate: identity, admission, revision checks, lifecycle truth, grants and
receipt reconciliation remain host-owned. The owner protocol is deliberately host-only; it is
not an extension component or a grant to an execution-scoped model. The Rindabox operations view
is a consumer presentation over these operations. Native Threading exposes remote automation configuration and history through the same owner
protocol. Worker/session adoption remains separate; autonomous work is not silently imported
as ordinary Mac chat sessions.

Validation adds migration/inbox/outbox checks and shared knowledge grant/revocation/provenance
checks, plus real owner-RPC text transport, invalid request/cleanup and denied MCP access. On 2026-10-04 `scripts/test-controller.sh` ran 63 core and 4 runtime Swift Testing cases, 9
real-CLI checks, the automation CLI script, 11 real-ptyd/MCP/supervisor checks, and 5 mail, 2
source, 1 usage and 3 host-state process checks, all passing on macOS arm64; the run's own output
is the current count. The final macOS/Linux rerun status is recorded with the consumer validation.


The opt-in sparse-history fixture is `scripts/tests/profile_controller_operations.py BINARY`.
On 2026-09-30, two Debug CLI reads had median/max 61.64/125.73 ms before and 67.08/111.38 ms
with 100,000 opaque closed records; manufacture took 1,350.25 ms separately. The query plan used
`unresolved_delivery (sequence>?)`, and no closed payload was decoded. These timings include two
process startups on a busy development machine, not resident latency or model execution.

## Host-owned recurring automations

Controller schema v5 adds an indexed due-time table. `ControllerAutomationSpec` names an existing
worker, instructions, an optional schedule, missed-run policy and archive preference. It cannot
change the worker's recipe or permission scope. The resident supervisor admits at most eight due
occurrences before its existing bounded execution pass. The schedule, occurrence receipt and work
item commit in one transaction, with no Mac dependency. A nil schedule supports explicit run-now
or an owner event adapter using stable request keys.

Owner CLI and SSH `owner-rpc` expose:

- `workers [CURSOR]`, `automations [CURSOR]` and `automation ID`;
- `automation-configure ID EXPECTED_REVISION SPEC_JSON_FILE` (zero creates; always pauses);
- `automation-enable ID REVISION`, `automation-pause ID REVISION`, `automation-delete ID REVISION`;
- `automation-run ID REVISION REQUEST_KEY` and `automation-runs ID [CURSOR]`.

A spec contains `name`, `workerID`, `instruction`, `schedule`, `missedPolicy` (`skip` or `latest`),
and `archiveOnSuccess`. A schedule's `kind` is `daily`, `weekdays`, `weekly` or `interval`, and its
`timeZone` is an IANA identifier. Calendar fields are `hour`, `minute`, `days` (Sunday=1); intervals
use `intervalMinutes` and optional ISO-8601 `anchor`. The same calendar code lives in
`ThreadingDomain` for both Mac and controller. Instructions travel as bounded text-file content
in owner RPC, never as shell syntax.

Every configuration or enable/pause/delete transition increments the revision. Stale changes
fail with conflict. Deletion is a tombstone and retains run history. A repeated manual request key
returns its original run only for the same revision. Running, queued or waiting work prevents
another occurrence; unresolved launch state does too. A late schedule records one missed receipt
or queues one catch-up, then advances past now. It never expands all missed periods into work.

Remote `archived` is a presentation fact, not deletion: a run must opt in, its work must complete,
all result deliveries must be confirmed, and no process launch may remain unresolved. Pending
questions, interrupted work, uncertain delivery and merely exited processes stay visible. The
Mac's Remote page and agent tool read this same controller projection. The execution-scoped
`agent-mcp` cannot administer schedules or grant itself owner authority; an owner-authorized
Threading agent uses the owner's SSH administration path, and its enable or run waits for the
Mac's approval sheet.

The supervisor admits each due automation in its own savepoint. One that cannot be admitted (an
enqueue refusal, an archived worker) rolls back alone; the supervisor then
records that occurrence as a `refused` run with the reason (for example `forbidden`, when the
worker no longer accepts scheduled work) and moves the rule to its next occurrence. A refused
occurrence is never retried later and relabelled `missed` by the lateness rule. Only a rule
whose next occurrence cannot be computed is retried after five minutes. Each failure also
leaves an `automation.admission_failed` event; a failure of the whole admission pass is reported
in the cycle's `automationIssues` and never stops launch supervision. A `latest` catch-up is
labelled with the most recent occurrence it replaces. `automation-runs` pages are bounded by
their encoded size (1 MiB) as well as their count, because each status carries its latest result.
Retrying interrupted automation work re-enters that automation's single slot: it is refused while
a newer occurrence is active, and afterwards later occurrences see it as busy. A spec file may
hold up to 200 KiB so that a full 32 KiB instruction survives JSON escaping; the instruction
itself keeps its own limit.

Validation: `ControllerAutomationTests` exercises the production store and shared recurrence;
`scripts/tests/test_controller_automations.py PATH_TO_CONTROLLER` drives the actual CLI and owner
RPC through creation, activation, inspection, retry-safe run-now, pause and deletion. These use
scratch databases and do not deploy or activate production VPS work.

## Remote worker provisioning trial

Owner RPC now admits `worker-configure`, using the same bounded launch-spec decoder and revision
fencing as the local command. Configuration remains paused until explicitly enabled. HTTP
consumers must construct recipes from trusted deployment settings; agent task text cannot select
an executable, environment, recipient policy or destination. This is owner authority, not an
additional execution-scoped MCP tool. Rindabox owns mailbox identity/provisioning, encrypted
SMTP credentials, task-to-recipient binding and mail receipts; none enter the portable package.

The 2026-09-30 trial's source snapshot passed 23 core, nine CLI and ten real-PTY checks on macOS.
The Linux x86_64 build passed core/CLI checks in a bounded compiler container; its stripped binary
passed nine CLI checks on the VPS, then all ten runtime checks against the installed ptyd binary
in isolated synthetic state. The private production supervisor is active. Provider flag parsing
passed; authenticated execution remains unverified because the VPS account is logged out.
Artifact provenance and the application activation record belong to Rindabox's infra/CONTROLLER.md.


## Requests, messages and lifecycle (schema v6)

`worker-reconcile ID REV RECIPE_FILE` atomically updates the trusted recipe while preserving
pause/enabled intent and concurrency. Repeating an identical recipe is a no-op, including its
revision. Admission must use this command rather than configure/pause followed by enable:
a lost response between two mutations must not strand a worker or override a human pause.

`worker-set-sources ID REV request,schedule,event` restricts admission sources. This is owner
policy, not agent input. Legacy workers without the record keep their previous behavior;
request-only consumers explicitly configure `request`. Automation due ticks use `schedule`;
manual owner requests use `request`. Execution MCP cannot change this policy or enqueue work.

`enqueue-request` stores a bounded immutable request envelope alongside the instruction.
`work-message` appends an idempotent, attributed follow-up to one unfinished task. Agents read
paged `work_messages`, then acknowledge individual IDs with `work_message_consumed`. Merely
listing messages is not acknowledgement. Completion and pending-message checks share one
transaction: a concurrent follow-up is either included before finish or rejected after finish.
Messages supply context; they do not answer questions or expand execution authority.

`work-history` / scoped `work_history` read an append-only task activity stream. Checkpoint
text is retained with source and execution identity instead of only replacing the current
checkpoint. Reads are bounded and indexed by task. History starts with upgraded writes;
checkpoint text overwritten by older releases cannot be reconstructed.

`work-cancel` retains the request and activity, closes an unanswered question, and rejects
running work or unresolved launches. Stop/reconcile a process before cancelling it.
`worker-archive` pauses the worker and retains a tombstone; outstanding tasks, unresolved
launches and enabled schedules block archival. In the same transaction it pauses (revision-bumps,
never deletes) every enabled trigger that admits work for the worker, and clears the wake flag on
mail already open in its inbox; new mail to an archived worker is refused at acceptance. All
future claims, configuration, enabling and admission reject archived workers, so a trigger
re-enabled afterwards records `refused` receipts rather than work. Schema v6 adds an index to
bound the active-schedule check; the trigger pause reads the active-trigger partial index.

### Work dependencies

`enqueue`/`enqueue-request` take an optional trailing comma-separated list of up to 16 work UUIDs
that must complete first (`dependsOn` on the work record). Each must already exist and must not
be cancelled, so the graph is acyclic by construction, and each item may be named by at most 64
dependents. A retry with the same key must name the same dependencies. Claims skip queued work
with an incomplete dependency in the same indexed query that skips launch-held work; an
interrupted dependency keeps its dependents waiting until it is retried and completes. Cancelling
work cancels its queued dependents, transitively and in the same transaction, recording
`cancelReason: "dependency_cancelled: <id>"` on each and in its activity. Dependents are found
through `workDependency` rows (dependency → dependent) on the parent index, and a cascade visits
only queued work, so its cost is bounded by the active queue rather than by completed history.

These remain host-owned operations. Consumer UI may present requests, forms, history and
permissions; consumer authentication determines the caller. Neither a message nor a form
submission becomes a recipe, shell command, recipient attestation or permission grant.

## Agent mail (schema v7)

Durable, addressed messages between agents, on this host and through peers on others. The
proposal and its reasoning are [`agent-mail.md`](../feature-drafts/agent-mail.md); this section is
what the controller implements. `ControllerMail.swift` holds the model and store operations,
`ControllerMailTransport.swift` the wire protocol, `ControllerMailSync` (runtime) the client half.

- **Identity.** Each store mints a stable `HostID` once (`host`, renamed with `host-set-name`).
  An address is `<host>/worker/<uuid>` or `<host>/session/<uuid>`; the host part is where the
  agent's process runs. Session mailboxes are registered (`mail-register`); workers need none.
  A session mailbox's tool credential is issued by the owner for each launch (`mail-credential`)
  and stored only as a digest, so each issue (and `mail-credential-rotate`) replaces the previous
  one in the same transaction; issuing is the revocation. The Mac provisions once per session per
  app run, so a still-running process of that session keeps its credential until it is relaunched.
- **Sending is storing.** `mail_send` succeeds once the message is in a store: the recipient's
  inbox on this host, or the outbound queue (`mail_outbound`, one row per message per peer host)
  for another. Busy, idle and not-running recipients differ only in when they read it. Refusals are
  authority (no grant, an interrupt the grant does not allow), bounds and unknown addresses.
- **The sender is authenticated.** An agent's sender is its execution's worker; the owner CLI
  (`mail-send`) attests a local mailbox; a peer may vouch only for senders on its own host, and
  only for recipients on this one, so nothing is relayed.
- **Grants live on the recipient's host** (`mail-grant-set RECIPIENT PATTERN REV mode priority`):
  exact sender, `<host>/*` or `*`, most specific first, revisioned, a `none` mode revokes. Modes
  are ordered `notify < wake < ask`. A reply to mail the recipient itself sent needs no grant —
  unless the owner explicitly revoked its sender: an effective `none` refuses replies too, and
  writing it answers the questions that worker's open work asked of that sender with a host
  refusal ("Undeliverable: … revoked"), so the work continues instead of waiting for a reply that
  can no longer arrive.
- **Reading is not acknowledging.** `mail_inbox` reads open mail through the `mail_open` partial
  index with a host-vouched header line per message; `mail_ack` records the acknowledging
  execution. An unacknowledged `interrupt` refuses `work_finish` in the finish transaction.
- **Chains bound loops.** A message continues the chain of what it replies to, or of the deepest
  mail its execution read, acknowledged or was woken by, so neither omitting `reply_to` nor never
  calling `mail_ack` escapes the depth limit (4). (Measured before: two workers waking each
  other and reading without acknowledging ping-ponged twelve rounds at depth 0.) A task mail
  started inherits the waking message's chain when it is claimed, so its spend is that chain's
  on its receipt too. The context record's `parent` is the chain id, which makes "executions in
  this chain" one indexed read. A
  session mailbox has no execution, so its acknowledgements carry into its sends until a person
  starts a new turn: the Mac resets the context (`mail-context-reset`) on a prompt a person wrote
  — a native chat's composer, or a terminal prompt that is neither the mail notice
  (`MailNoticeWords.prefix`) nor a cross-session delivery. Stop-hook continuations, typed notices,
  deliveries and wakes keep agents going unattended, and the shared chain is what bounds them;
  a person's next prompt always starts fresh. (Tried first and rejected: keeping the context
  forever, consuming it on the next send, a time window, and reply-only chains — each either
  refused legitimate mail or let an unattended exchange escape its bound.) Owner admission is the
  same-project default, never an override: a revocation for the sender stands. A reply to a forwarded
  copy carries `answeringFor` — the address the original reached — which only the same mailbox
  id on another host may claim, so a mailbox that moved still answers what was asked of it; a
  mailbox that moves onto the asker's own host replaces the asker's sent copy rather than
  colliding with it. Wake admission keys on the newest open message that may wake the worker
  and whose chain is within budget, not on whichever message arrived last. Fuses
  that need no reading: 50 messages and 16 wakes per chain on a host, 20 sends a minute per
  sender, 1,000 open messages per inbox. Spend limits belong to admission ([usage ledger](../feature-drafts/agent-usage-ledger.md)).
- **Notices, not bodies.** `threading-controller agent-notice post-tool-use|stop|session-start` is
  the hook command a recipe installs. It prints one host-authored line naming counts, senders and
  hosts as hook JSON (`hookSpecificOutput.additionalContext`, or `decision: block` once per
  message at a stop) and always exits 0. Measured on Codex 0.160.0 and the Claude Code hook
  contract; a model may ignore a notice, which delays mail but cannot lose it.
- **Ask.** `mail_ask` sends a question as mail and yields the work in one transaction; the
  question's recipient is `agent:<address>`. The reply (`reply_to` that message) answers it on the
  asker's host and requeues the work. A question the recipient's host refuses is answered by the
  asker's host with the refusal, so the work continues instead of waiting forever.
- **Wake.** Mail admitted under a `wake` or `ask` grant may start an idle worker: the supervisor
  admits one `event` task per worker with no open work, keyed by the newest open message, so a
  restart cannot duplicate it and unread mail cannot loop. The owner still decides through
  `worker-set-sources … event`. The claim admits it again (`mailWakeAdmission`): a revocation,
  a spent chain budget or an inbox emptied since admission withdraws the queued task as
  cancelled (`mail.wake_withdrawn`) instead of running it. A claim records the newest open
  sequence as what that wake saw (`mailWakeMark`); only mail newer than the mark wakes the worker
  again, so a task that acknowledges one message of five is not re-woken once for each of the
  other four. (Measured before: five wakes for five messages.)
- **Transport.** `mail-rpc --peer HOST` is the forced command of a per-peer SSH key: one JSON
  request (≤ 2 MiB) — `push` a batch (≤ 100 messages / 1 MiB) or `pull` after a cursor that
  acknowledges what the caller already stored, with the caller's refusals of that page. Every
  response names the answering host, and the caller refuses a response from any other. A pulled
  page and the pull cursor commit together. A message the puller could not write (a storage
  error, reported as `unavailable`) is not a refusal: the page stops there without moving the
  cursor, so the whole page is offered again and what was stored returns as duplicates; a holder
  that receives an `unavailable` refusal from an older puller re-queues the message. (Before, the
  transient failure was reported back as a refusal and bounced the message permanently, answering
  a question it carried "Undeliverable".) The supervisor runs one sync pass every 15 s beside
  launch supervision; `mail-sync` runs one pass by hand. Peers are owner-authored (`mail-peer-set`
  with the transport argv), and only peers with a transport are initiated to.
- **Outbound mail ends.** Mail queued for a peer bounces to its sender — state `bounced`, a
  carried question answered "Undeliverable: this host stopped trying…" — when the owner cancels
  it (`mail-outbound-cancel MESSAGE`) or after seven days in the queue (`queuedAt`). The
  supervisor expires a page per pass from the head of the queue, which is in queueing order, so
  the scan stops at the first message still within its lifetime.

- **Moving a mailbox** (`ControllerMailForward.swift`). A forward is owner-written and
  revisioned, keyed by the old address (`mail-forward-set OLD NEW REV`, `mail-forward-clear`).
  On the old store it forwards mail still arriving for the old address once — after the old
  address's own admission — re-addressed in place or queued to the new host as `moved`. On the
  new store the same record is the owner's consent to take copies carrying `forwardedFrom` from
  that host without a grant — but the old host still vouches only for what it can: senders on
  itself, or a sender on the receiving host whose copy of that very message the receiving store
  already holds (a mailbox moving back, or onto the sender's host). Any other sender on this
  host is refused. A sender on a third host is the old host's word alone: it is accepted only if
  this store also peers with that host, and then only under this store's own grants for that
  sender (the handover copies the old mailbox's grants), never under the forward's consent, and
  urgent only where a grant allows it — so a Mac session's mail to a hosted session still follows
  a host-to-host move. (Before, the forward let the old host inject mail as any sender,
  including this host's own agents, urgent and under any name.) A forwarded copy's header says
  "forwarded via <old host>". The consent lapses seven
  days after the forward was written (`acceptsUntil`); re-writing it renews. An explicit
  revocation on the receiving store stands against forwarded copies too. A copy that was
  forwarded once is never forwarded again. `mail-move OLD NEW` moves unacknowledged mail in one
  transaction with ids kept, so the receiver's idempotence makes a retry harmless; a mailbox
  moved away and back replaces the `moved` copy it left under the same id.

Validation: `ControllerMailTests` (11 core cases: grants and revocation, busy recipients, notices,
interrupts and finish, chain depth, ask/reply, wake coalescing, rate fuse, sessions, push/pull
idempotence and spoofing, refused questions, v6 upgrade), `ControllerMailAuthorityTests` (unacked
wake ping-pong bounded in one chain, a budget held by unsettled and admitted spend, forward
vouching and lapse, replies after revocation, a queued wake withdrawn at claim, no re-wake after a
partial ack, an unwritable pulled page pulled again, credential rotation, outbound cancel and
expiry) and `scripts/tests/test_controller_mail.py`
(real ptyd and two stores: a question crossing hosts wakes the recipient, its reply is pulled and
the asker continues; a moved session keeps its unread mail and late mail is forwarded once; a busy agent receives the notice through the real hook command and cannot
finish before acknowledging; unknown peers, forged senders and a transport reaching the wrong host
are refused; a rotated session credential locks out the old one through the real `agent-mcp`; an
owner-cancelled outbound message bounces and is never pushed).

## Trigger sources (schema v8)

Waking a worker on facts rather than on a model turn: **source → match → admit → run**. The
proposal is [`portable-trigger-sources.md`](../feature-drafts/portable-trigger-sources.md);
`TriggerProbe.swift` (contract, runner, SHA-256) is shared with the Mac's `threading-triggerd`,
`ControllerSources.swift` owns records, `ControllerSourcePoller` (runtime) runs a poll.

- **A source is any executable on the probe contract**: one JSON request on stdin
  (`cursor`, `limit`), JSON lines of events and exactly one final cursor on stdout, exit 0 / 75
  (back off) / 77 (authentication needed). It runs with exactly the configured environment
  (nothing inherited) in a private per-source directory, in its own process group, which the host
  kills on timeout, on a report over 1 MiB and when the probe exits. Invalid output fails the poll
  and commits no cursor. Examples ship in `Packages/ThreadingController/Examples/Probes`.
- **Approval pins content.** `source-configure` always pauses and clears approval; the owner
  approves the SHA-256 it was shown (`source-approve ID REV HASH`), which must still match the
  files on disk. The poller hashes before running anything: an edited executable or script is
  never run, and the source shows `changed` until approved again. A probe is not sandboxed — it
  has this account's authority — which is why approval names the exact content.
- **Secrets by name.** A spec maps environment variables to secret names; `secret-set` writes an
  owner-only file beside the database that no command reads back, resolved only into the probe's
  environment at poll time.
- **Match and admit without a model.** A trigger is a typed AND rule over one source's event
  fields (`equals`, `notEquals`, `prefix`, `notPrefix`, `contains`, `exists`, `absent`; a missing
  field matches only `absent`). A match enqueues `event` work for the trigger's worker with a
  host-authored instruction; the event (fields and bounded evidence) travels as the work's
  immutable request, never as configuration. Enabling a trigger needs the worker to accept `event`
  admission. Events are stored once per (id, revision), so redelivery admits nothing twice, and
  each event keeps a receipt per trigger (`queued`, `notMatched`, `refused` with the reason).
- **Admission is bounded** (`TriggerAdmissionLimits`). Events commit in chunks of at most 25
  events or 20 admissions, so the write lock is held briefly and a crash between chunks only
  leaves the cursor unmoved for a deduplicated redelivery. A trigger already holding 50 queued,
  unclaimed tasks records `refused` with reason `backlog` (counted through the scope/state index,
  O(ceiling)); claiming frees room. One poll admits at most 100 tasks across all triggers: once
  reached, later events are not recorded, the cursor stays put and the next poll runs within a
  minute, so the probe redelivers them. Before this, a 500-event × 20-trigger burst admitted
  10,000 tasks in one transaction (11.5 s on a loaded macOS Debug host, load average about 210);
  with the bounds the same burst admits 1,000 over eleven polls and 96 commits, and the longest
  write transaction measured 0.16-0.42 s under the same load (`ControllerSchedulingMemoryTests`
  asserts the ceilings and a 1 s bound).
- **When it polls.** An interval (60 s – 1 day) or a calendar `AutomationSchedule` — so "every
  ten minutes, check the mailbox" spends nothing until mail arrives. Failures back off
  exponentially to an hour without moving the cursor. The deadline is claimed before a poll runs,
  so a crash waits one interval instead of polling in a loop. The resident supervisor runs at most
  two polls at once beside launch supervision, from a due-time index (`source_due`).
- **Mail is the built-in source.** Mail admitted under a `wake` grant is the controller's own
  source with a fixed trigger (one coalesced inbox task per idle worker), described under Agent
  mail above; it needs no probe.

Validation: `ControllerSchedulingMemoryTests` (burst bounds and backlog ceiling, refused
automation occurrences, archive pausing triggers and wake, dependency ordering and cascade, memory
delete/forget/quotas/provenance including erasure from the live files, knowledge provenance and
forget, retention keeping dedupe), `ControllerSourcesTests` (SHA-256 vectors, output parsing, a real probe's environment,
exit codes, the timeout killing a probe's child, output flood, approval/enable/match/dedupe/
backoff/changed) and `scripts/tests/test_controller_sources.py` (a resident supervisor polls the
shipped `file_drop.py`, admits one `event` task for a matching file, ignores a redelivery, refuses
to run an edited probe; a secret reaches a probe by name and its absence fails the poll with the
cursor kept).

## Usage receipts and budgets (schema v9)

What each agent spent, kept on the host that ran it. The proposal is
[`agent-usage-ledger.md`](../feature-drafts/agent-usage-ledger.md); `ControllerUsage.swift` owns
receipts, daily cells and budgets, `ControllerUsageCollector` (runtime) reads transcripts.

- **One parser.** Transcripts are read through `Packages/ThreadingUsage` — the same Claude and
  Codex adapters, strict reader and pricing catalogue as the Mac's Usage page — so a worker's
  spend and a Mac session's spend are computed by identical code.
- **A receipt per execution, owed from the confirmed stop.** A recipe names its transcripts with
  `usage` (contract below). Confirming a launch stopped records it in `usage_pending` in the same
  transaction; the supervisor writes receipts beside supervision (two at a time), and
  `usage-collect` writes one by hand. Attribution — worker, task, the mail chain the execution
  acted on, the trigger whose event admitted it, the account — comes from controller records only.
- **Declared accounts, in attempt order (the multi-account contract).** A runner that fails over
  from an exhausted login resumes the conversation under the next one, which copies the transcript
  into that login's home. The recipe declares every login it may use:

  ```json
  "usage": {
    "runtime": "claude",
    "accounts": [
      {"account": "work",  "home": "/srv/agents/claude-work"},
      {"account": "spare", "home": "/srv/agents/claude-spare"}
    ]
  }
  ```

  `runtime` is `claude` or `codex`; `home` is the absolute `CLAUDE_CONFIG_DIR`/`CODEX_HOME`;
  `account` is the name spend is attributed to (≤ 256 bytes). 1–8 entries, distinct names, homes
  that are distinct and do not nest. The legacy shape `{"runtime", "home", "account"?}` remains
  valid and is one attempt named by `account` (or by `home` when unnamed); stored policies keep
  working unchanged and re-encode without an `accounts` key. A recipe may carry both shapes so a
  controller older than this contract still reads `home`/`account`; they must then equal the first
  entry, or validation refuses `usage_accounts_conflict`. `--version` lists `usage-accounts`.
- **Binding each attempt.** The authenticated `agent-notice` hook reports `{session_id,
  transcript_path}`. A path inside a declared home binds that attempt (one binding per home,
  recorded on the launch as `providerTranscripts: [{account, sessionID, path}]`, in report order;
  `providerTranscript` stays the first). Repeating a binding is a no-op. A path outside every
  declared home (`forbidden`) or a different session/path in an already bound home (`conflict`)
  marks the launch `providerTranscriptChanged`, and its receipt is `partial`.
- **Finding transcripts.** Every declared home is read. Claude: the bound path when there is one —
  it must resolve, symlinks included, inside `<home>/projects/` and be named `<execution>.jsonl` —
  otherwise `<home>/projects/*/<execution>.jsonl`, plus `subagents/` (at most 200). Codex: the
  bound rollout, whose first line (read through its own 1 MiB bound) must be `session_meta` with
  the bound session ID, plus `<home>/threading-subagents/<execution>/*.jsonl` (at most 200,
  resolving inside the home) — Codex has no per-session folder, so a child run the execution
  started itself, such as a research helper's own `codex exec`, is filed there by whoever started
  it. A home with no transcript and no binding was simply not used.
- **Counted once, on the earliest account.** Records from all homes merge by response identity
  through ThreadingUsage's `mergingUsageMaximums` (component-wise maxima, the Mac's one merge), with
  attribution to the earliest declared account the identity appears in. A copied history therefore
  adds nothing and stays on the first login; the responses made after the failover land on the
  second.
- **Receipt shape.** `account` is the first declared account. Each cell carries `account` beside
  `model`, five token categories, `requests`, `costUSD`, `unpricedTokens` and `catalogCostUSD`
  (the catalogue-estimated part of `costUSD`). `accounts` lists every declared account in attempt
  order, including those that spent nothing:
  `[{"account","tokens":{…},"budgetTokens","requests","costUSD","unpricedTokens"}]`.
  `pricingVersion` names the catalogue. Cells are bounded to 15 plus one "other models" cell per
  account, so per-account totals stay exact. Receipts written before this contract lack these
  fields; their cells belong to the receipt's `account`.
- **Keep what was read; name the gap.** Receipts read through ThreadingUsage's recovering reading:
  an unreadable usage line or an unterminated final line (a writer stopped mid-record) keeps every
  readable record and makes the receipt `partial` with a reason (`unreadable_usage_records`,
  `transcript_unterminated`, `subagent_transcripts_incomplete`, `provider_transcript_identity`,
  `provider_transcript_unreadable`; prefixed `account: ` when several accounts are declared). A
  bound transcript that cannot be read at all is `failed`. Cells are priced by provider report
  or the catalogue; unpriced tokens are counted separately.
- **Zero is settled, not guessed.** A launch that never dispatched (an obsolete preparation, a
  stop confirmed before spawn) settles `complete` with reason `never_spawned`. A spawned run with
  no transcript and no binding in any declared home settles `complete` with
  `no_provider_session`: Claude writes its transcript before its first request, and Codex's
  session-start hook binds before its first turn — which is why the hook is required even for
  mailbox-free workers. Claude homes that all lack a `projects` directory are a misconfiguration,
  `unavailable` (`no_projects_directory`).
- **Reads are O(days × cells).** Each receipt adds to `usage_daily` (day, worker, account, model)
  under each cell's own account, in its transaction; `usage-summary FROM THROUGH` pages those
  cells, `usage-receipts WORKER` pages receipts. Both go through `owner-rpc` for the Mac's Remote
  page and Rindabox. Each daily cell is labelled from a `usageDailyLabel` record (no DDL; joined
  on SQLite's own `json_array(day,worker,account,model)` key): `unpricedTokens`, `catalogCostUSD`,
  `pricingVersion`, `costIsEstimate` (any catalogue estimate or unpriced tokens — the figure is not
  an invoice) and `coverage` counts of the receipts behind it. Cells written before labelling have
  these fields absent.
- **Budgets act at admission, in budget tokens** (uncached input + cache writes + output; cached
  reads excluded because a long conversation rereads its context every turn). A worker's daily
  budget (`worker-budget-set`) stops the supervisor starting new executions for it; a mail
  grant's chain budget stops that chain's mail from waking its recipient, while still delivering
  it. Spend that is not known yet counts as unknown, not as zero: while any execution in the
  chain has unsettled usage, or a wake admitted in it has not started, the budget holds further
  wakes in that chain (a waived or settled receipt releases it). Nothing running is ever stopped
  by a budget. Chain totals are those of executions on this host. A fraction-of-account-window ceiling needs usage readings this host does not take yet.
- **Manual launches pass the same budget.** `launch`/`launch-prepare` judge the worker's budget on
  the recipe they will run (no usage source, unsettled usage, or spend past the day's budget refuse
  with `worker_capacity_<reason>`). `--override-budget` admits anyway and records
  `launch.budget_overridden` with the refused reason. The paused flag and capacity holds are
  supervisor policy and do not apply.
- **Waiving.** `usage-waive EXECUTION REASON` (owner CLI and `owner-rpc`) releases one stopped
  execution's unsettled-usage hold when no transcript can settle it: a `usageWaiver` record and a
  `launch.usage_waived` event carrying the reason on the work's activity. It is idempotent, refuses
  an execution still running or already settled (`conflict`), and leaves collection owed, so a
  transcript that appears later is still counted.
- **Capacity holds.** `capacity-hold-set ACCOUNT UNTIL REASON` (ISO 8601 `UNTIL`),
  `capacity-hold-list [CURSOR]` and `capacity-hold-clear ACCOUNT` (all on `owner-rpc`) record an
  owner signal that an account is scarce — for example a provider cooldown Rindabox observed.
  Supervised admission defers a worker (`worker-capacity` reason `capacityHeld`, with `heldUntil`
  the earliest release) only while **every** account its recipe declares has an unexpired hold; a
  worker with no usage source is never held. Holds are owner input, never inferred from token
  totals. `--version` lists `usage-waive` and `capacity-hold`.

Validation: `ControllerUsageTests` (receipt idempotence and daily cells, a stop that owes nothing,
the daily budget at admission, a chain past its budget delivering without waking, `usage-waive`,
manual launch budget refusal and override, capacity holds deferring admission, the usage source
contract and its legacy compatibility, one binding per declared home, per-account daily cells and
labels); `ControllerRuntimeTests/UsageCollectorTests` (failover across two declared homes with a
copied transcript counted once per account, never-spawned and no-session zero settlement, the max
merge of repeated responses, a truncated final line kept as partial, bound Claude path enforcement,
a Codex `session_meta` line past 64 KB); and `scripts/tests/test_controller_usage.py` (an agent
under ptyd writes a Claude transcript and the resident supervisor writes a complete, priced,
attributed receipt and then holds a worker past its budget; a runner fails over between two
declared homes through the real `agent-notice` hook; `owner-rpc` waives usage, sets and clears a
capacity hold, and a manual launch is refused and then overridden).

## Host hardening and observability (schema v10)

Controller and ptyd remain separate portable services. Rindabox is a consumer of the owner
protocol; business prompts, grants and destinations remain application-owned. The owner
protocol is local Unix-account authority, never a tenant-facing HTTP or unrestricted MCP API.
Use a distinct OS account/container for clients requiring mutual isolation.

Usage collection requires a confirmed stop. Launches persist start/stop timestamps; receipts
carry duration and provider session identity without exporting prompts, argv or credentials.
Daily cells use the recorded stop day, including delayed collection. Codex transcript identity
comes from the provider's authenticated `agent-notice` hook (`session_id`, `transcript_path`),
not directory/time inference. Install the hook even for mailbox-free workers. An unbound path,
identity mismatch, unreadable child directory or capped child set is an explicit coverage gap.
Claude's execution UUID remains its exact session lookup, and a bound Claude path must resolve
inside the home and name the execution. An authenticated hook may bind one transcript in each
home the recipe declares (account failover); a changed session/path within a home, or a path
outside every declared home, marks coverage partial. Receipts split per declared account (see
above). Complete receipts are immutable.

A capped worker reserves the remaining daily capacity for one execution until accounting is
complete. Unknown, partial and pending usage hold new admissions for that UTC day unless the
owner waives them; unresolved processes retain their reservation across days. A budgeted recipe
with no usage source is held, for manual launches too.
This is a conservative admission policy, not a hard upper bound on a running provider's spend:
provider turn limits and process deadlines still bound individual runs. `worker-capacity` names
the reason and stable host authority, leaving an explicit seam for later account/window policy.
Account coordination across hosts is not claimed. Never infer subscription-window percentage
from token totals. Credentials stay on their execution host.

The unsettled set is indexed by worker/day; admission reads one row, not historical launches.
Expected concurrency is 1–8 per worker, 32 per store; retained launches may exceed 100,000.
Trigger dispatch indexes active rules and supports at most 100 enabled rules per source.
Paused/deleted history does not consume this limit; enabling excess rules is refused before
admission. Existing over-limit stores fail the poll without advancing its cursor.

Wake admission, and again the claim of a wake task, rechecks current mail authority. Explicit
revocations prevent future work even from retained mail, and refuse replies. Mac default provisioning preserves revocations; its bounded eight-host sync
pass rotates through all hosts. Mail transport and probes share `BoundedCommand`: private process
groups, nonblocking bounded streams, bounded cleanup, and no unbounded wait for descendant EOF.
A descendant that leaves the group (`setsid`) survives the group kill; the run then reports
exit 0 with a `failure`, and both callers treat any failure as a failed run (audited; pinned by
`ControllerHardeningTests/anEscapedDescendantFailsTheRunEvenAfterExitZero`). On Linux the
cleanup also kills processes still holding the command's output pipes, found by pipe inode in
`/proc` (bounded scan), reported as `escaped_descendant_killed`. macOS has no such sweep: the
escapee survives and is reported. Containment beyond that needs a cgroup or container boundary.

`scripts/test-controller.sh` runs core, runtime, CLI and real-ptyd suites, including
`ControllerRecoveryTests` and `scripts/tests/test_controller_recovery.py` (ptyd SIGKILL with two
restarts, fork failure under `RLIMIT_NPROC`, a watcher-observed exit outliving supervisor
downtime, a 12 s write lock against the resident loop, an old supervisor after migration, and
fenced owner-RPC repair; each fails against the 0708ee200 binaries). It uses the existing
XCTest harness watchdog on Linux; Swift Testing failures are not retried. The standard Mac CI
and a separate Ubuntu lane both invoke it. `threading-controller --version` reports protocol,
schema and capabilities without opening or migrating a database. Before an upgrade, take a
`host-state.py capture` (store and secrets); older binaries refuse schema 10. Restore into an isolated private directory
with workers/sources disarmed before testing, never alongside active copies of the same work.

A reusable Linux distribution path is `scripts/build-controller-host.sh OUTPUT` inside a
Linux Swift toolchain. It runs all controller/ptyd process checks and emits controller (glibc,
static Swift runtime, stripped at link), ptyd (the static musl, generation-stamped build of
`scripts/linux/build-ptyd-static.sh`, with the daemon suite run against that exact file), a
SHA-256 manifest of those final bytes, `install-host.py`, and `host-state.py`, then runs
`install-host.py` against a throwaway home. Consumers must not strip or rewrite bundle files after
the manifest: the installer refuses any digest mismatch. Installation verifies architecture,
content and protocol before writing private per-user files. A ptyd install refuses
(`ptyd_socket_in_use`) when a live daemon of another state directory already answers `hello` on its
socket, the same rule the daemon applies to itself at startup (pty-host.md, "Failure model"), and
writes `external:threading-host-bundle` into its release directory's `.threading-managed-by` so the Mac's
Remote Hosts setup never retires or prunes it. It does not start services unless
`--start` is supplied and refuses an implicit replacement of an existing unit. Existing-host
upgrades remain an explicit stop, online snapshot, verified artifact/unit switch, restart and
health-check operation. Rindabox's Ansible adapter retains its own destinations and credentials.
`host-state.py capture` writes a snapshot directory: the integrity-checked online database backup,
a copy of the store's `secrets/` (owner-only modes kept; symlinks, shared modes, more than 4096
entries or a file over the controller's own 16 KiB bound are refused, leaving nothing behind), and
a small manifest. The schemas it accepts are `1…N` where `N` is the bundled controller's
`--version` schema, so a schema bump needs no edit there. `host-state.py restore` preserves
identity and records but disarms workers, schedules, sources, triggers and peer transport, and puts
the secrets back beside the restored database, refusing an existing `secrets/`. It never launches a
restored execution or clears uncertainty. An older single-file snapshot still restores, without
secrets.

## Discoverable hosted memory

A hosted agent is identified by `(authorityID, agentID)`: the persisted controller host and
existing worker UUID. An execution or provider-session change does not mint another agent.
`work_context` includes this identity and the first 20 memory keys/revisions; `memory_list`
pages further keys through the worker/sequence index without loading note bodies. Agents read
relevant notes with `memory_get` and update them with compare-and-swap `memory_put`. All agent
routes derive the worker from the authenticated execution; none accepts another worker ID.
The owner protocol provides memory-list/get/put/history/delete/forget (and knowledge-forget) for
trusted administration; see memory lifecycle and quotas under Persistence and scaling.

Notes and revision history live in controller SQLite and travel with its backup; provider
transcripts and credentials do not. A regression reopens the store, starts a new execution and
checks recall and pagination; `runningAgentCannotReachAnotherWorkersMemory` has a running agent
ask for a second worker's known key, list, overwrite it and present its own credential for the
other worker's execution, and asserts each is refused or lands in its own namespace. That is the
whole guarantee: the agent **tool path** never names another worker. Workers on one host share
one Unix account, one controller database and the provider files under it, so a shell or file
read from an agent's process can reach another worker's notes; mutual isolation needs a separate
OS account or container per worker. This is the hosted memory core;
attaching persistent identities to native chats, promotion/profile UI and authenticated remote
chat attachment remain separate consumer work.
