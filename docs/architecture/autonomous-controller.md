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

`launch-prepare WORKER_UUID RECIPE_JSON_FILE` claims work and saves launch intent and a private
execution credential in one transaction. `launch-dispatch EXECUTION_UUID` connects, commits
`prepared -> dispatching`, then sends exactly one spawn. The PTY identity is the execution UUID;
replacement authority is never set. `spawned` records pid and kernel start time and changes the
launch to `running`. `launch WORKER_UUID RECIPE_JSON_FILE` composes these operations. Its process
can exit: ptyd owns the child, and tools use the host-local work store with no Mac dependency.

A failed connection before dispatch leaves a prepared intent that can be explicitly dispatched.
A lost spawn response leaves `dispatching`, which cannot be dispatched again. An explicit spawn
refusal other than `alreadyExists` confirms no process started and interrupts unfinished work.
There is no timeout-based reassignment. `launches WORK_UUID` finds saved intents after a lost CLI
response. Status output omits the recipe's argv/environment and the execution credential.

`launch-status EXECUTION_UUID` reads ptyd's inventory without attaching to or resizing a terminal.
It reports `running`, `stopped` or `absent`. A retained exit receipt confirms the launch stopped;
exit alone interrupts unfinished work, even for exit zero. It never invents a result. An absent
entry leaves the durable launch unresolved: ptyd retains exits for a bounded window, and restart
cannot prove an old process stopped merely by omitting it from inventory. A live inventory after
a lost spawn receipt may report `presence=running` with a still-`dispatching` durable launch;
this is observation, not a fabricated pid/start-time receipt.

`launch-stop EXECUTION_UUID` attaches to that exact identity, requests kill and waits for its exit
receipt before recording stopped. Timeout remains unresolved. `launch-confirm-stopped` is an
owner-only recovery assertion requiring independent evidence; it does not signal a process.
Answered work stays unclaimable while any prior launch is prepared, dispatching or running.
Other work remains eligible. The resident supervisor records available exit receipts before
launching continuations; manual users can do the same with `launch-status`. Provider grandchildren are subject to the
existing PTY process-group contract, not an OS workload/container boundary.

For intervention, the existing `threading-ptyd attach EXECUTION_UUID --socket PATH` observes the
real terminal; add `--input` deliberately to type. The autonomous controller discards PTY output
and never interprets ANSI output as work status. Its control inbox is capped at 64 frames/4 MiB;
each request has a bounded wait. Prefer noninteractive provider turns for unattended execution.

## Execution-scoped tools

The launched child receives the controller executable, database path, execution ID and private
credential in environment variables. `threading-controller agent REQUEST_JSON_FILE` exposes a
single typed operation; `agent-mcp` exposes the same operations over newline-delimited stdio MCP:
`work_context`, `work_questions`, `work_messages`, `work_history`, `work_message_consumed`,
`work_checkpoint`, `work_ask`, `work_finish`, `memory_get`, `memory_put`, `knowledge_get`,
`knowledge_put`. These adapters have no claim, answer, retry, stop, delivery acknowledgement, arbitrary
SQL or destination-selection tool. Question recipients and output destination come from the
immutable owner recipe. Memory derives its worker from the execution's work.

Admission, active-execution checks and mutation run inside one write transaction, using nested
savepoints to compose existing core operations. Terminal writes allow identical receipt retries
until the process is confirmed stopped; later memory writes and context reads require a current
running execution. A stopped launch revokes all tool calls. The credential never appears in
status/events; private recipe/database files are still sensitive. This is scoped tool routing,
not isolation from a malicious shell sharing the owner's Unix account.

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
`supervisor-tick` runs one bounded pass for diagnosis; repeatedly invoking it is not a substitute
for the resident loop, which retains fairness cursors.

Each tick reads at most eight unresolved launches and eight worker policies, wraps its cursors,
and sends at most two new spawn attempts. Inventory is shared once per socket in the page, with
at most eight concurrent bounded requests. One attempt is reserved for fresh work so repeated
connection failures on an old prepared intent cannot starve another worker. No transcript is
retained, no TUI is attached, and no external destination is invoked by the supervisor. Its JSON
reports contain counts, execution IDs and structural issue codes, never prompts or credentials;
idle passes emit nothing.

Admission and preparation share one SQLite write transaction. Per-worker limits count every
unresolved launch, including manual and uncertain launches. Automatic admission also has a
store-wide ceiling of 32 unresolved launches. An explicit manual owner launch can exceed those
scheduling limits; it still contributes to the supervisor's occupied slots. `active-launches
[CURSOR]` inspects these records without exposing recipes. Failed work stays interrupted until
an owner explicitly retries it. Missing inventory, timeouts and daemon restarts never authorize
an automatic replacement. A definite spawn refusal pauses the matching policy revision so a
broken recipe cannot consume the entire queue; a newer owner revision is not overwritten.

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

The supervisor also admits the host-owned recurring automations described below. It is not a self-healing service. Exit receipts
are still bounded by ptyd's retention window. An outage or sufficiently delayed observation can
leave a launch unresolved for operator reconciliation. Backup/retention, provider authentication,
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

Schema v6 stores small typed payload rows with indexes for kind, identity, parent, source key,
state and cursor. State indexes and payloads have one write owner. Reads decode only the requested
page; claims query the indexed queue. No partial read is written back as a complete catalogue.
Rows are retained in this slice, so source keys and receipts remain durable; retention/quota and
backup policy must be implemented before unattended production operation. Do not prune dedupe
keys or unresolved external effects as ordinary log cleanup.
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
provider transcript. Shared project knowledge, semantic search, memory provenance beyond the
revision journal, and provider context injection are not implemented. These records are context,
never a source of permission grants or system instructions.

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
immutable content history and record the actual execution ID. A running worker loses access on
its next call after revocation. No work text or shared content can issue grants. Existing
worker-local memory remains private to that worker's scoped tools. Shared knowledge is untrusted
context and may contain mistaken or malicious instructions; it is not host policy.

`owner-rpc` carries one command and up to 16 value/text arguments in at most 256 KiB of JSON on
stdin, returning one JSON response. Text arguments become private bounded host files and are
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
checks, plus real owner-RPC text transport, invalid request/cleanup and denied MCP access. The suite comprises 23 core, eight CLI and ten PTY/MCP tests. The final macOS/Linux rerun
status is recorded with the consumer validation.


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
unreadable time zone, an enqueue conflict) rolls back alone, is retried after five minutes and
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
launches and enabled schedules block archival. All future claims, configuration, enabling and
admission reject archived workers. Schema v6 adds an index to bound the active-schedule check.

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
- **Sending is storing.** `mail_send` succeeds once the message is in a store: the recipient's
  inbox on this host, or the outbound queue (`mail_outbound`, one row per message per peer host)
  for another. Busy, idle and not-running recipients differ only in when they read it. Refusals are
  authority (no grant, an interrupt the grant does not allow), bounds and unknown addresses.
- **The sender is authenticated.** An agent's sender is its execution's worker; the owner CLI
  (`mail-send`) attests a local mailbox; a peer may vouch only for senders on its own host, and
  only for recipients on this one, so nothing is relayed.
- **Grants live on the recipient's host** (`mail-grant-set RECIPIENT PATTERN REV mode priority`):
  exact sender, `<host>/*` or `*`, most specific first, revisioned, a `none` mode revokes. Modes
  are ordered `notify < wake < ask`. A reply to mail the recipient itself sent needs no grant.
- **Reading is not acknowledging.** `mail_inbox` reads open mail through the `mail_open` partial
  index with a host-vouched header line per message; `mail_ack` records the acknowledging
  execution. An unacknowledged `interrupt` refuses `work_finish` in the finish transaction.
- **Chains bound loops.** A message continues the chain of what it replies to, or of the mail its
  execution last acknowledged, so omitting `reply_to` does not escape the depth limit (4). A
  session mailbox has no execution, so its context is the mail it acknowledged *since it last
  sent*, consumed by that send: a ping-pong keeps its chain and stays bounded, while its next
  unrelated message starts a new chain. (Keeping the deepest context forever, as first shipped,
  refused every fresh message from a session after one deep exchange.) A reply to a forwarded
  copy carries `answeringFor` — the address the original reached — which only the same mailbox
  id on another host may claim, so a mailbox that moved still answers what was asked of it; a
  mailbox that moves onto the asker's own host replaces the asker's sent copy rather than
  colliding with it. Wake admission keys on the newest open message that may wake the worker
  and whose chain is within budget, not on whichever message arrived last. Fuses
  that need no reading: 50 messages per chain on a host, 20 sends a minute per sender, 1,000 open
  messages per inbox. Spend limits belong to admission ([usage ledger](../feature-drafts/agent-usage-ledger.md)).
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
  `worker-set-sources … event`.
- **Transport.** `mail-rpc --peer HOST` is the forced command of a per-peer SSH key: one JSON
  request (≤ 2 MiB) — `push` a batch (≤ 100 messages / 1 MiB) or `pull` after a cursor that
  acknowledges what the caller already stored, with the caller's refusals of that page. Every
  response names the answering host, and the caller refuses a response from any other. A pulled
  page and the pull cursor commit together. The supervisor runs one sync pass every 15 s beside
  launch supervision; `mail-sync` runs one pass by hand. Peers are owner-authored (`mail-peer-set`
  with the transport argv), and only peers with a transport are initiated to.

- **Moving a mailbox** (`ControllerMailForward.swift`). A forward is owner-written and
  revisioned, keyed by the old address (`mail-forward-set OLD NEW REV`, `mail-forward-clear`).
  On the old store it forwards mail still arriving for the old address once — after the old
  address's own admission — re-addressed in place or queued to the new host as `moved`. On the
  new store the same record is the owner's consent: a copy carrying `forwardedFrom` from that
  host is admitted without a sender-host match or grant. A copy that was forwarded once is never
  forwarded again. `mail-move OLD NEW` moves unacknowledged mail in one transaction with ids
  kept, so the receiver's idempotence makes a retry harmless; a mailbox moved away and back
  replaces the `moved` copy it left under the same id.

Validation: `ControllerMailTests` (11 core cases: grants and revocation, busy recipients, notices,
interrupts and finish, chain depth, ask/reply, wake coalescing, rate fuse, sessions, push/pull
idempotence and spoofing, refused questions, v6 upgrade) and `scripts/tests/test_controller_mail.py`
(real ptyd and two stores: a question crossing hosts wakes the recipient, its reply is pulled and
the asker continues; a moved session keeps its unread mail and late mail is forwarded once; a busy agent receives the notice through the real hook command and cannot
finish before acknowledging; unknown peers, forged senders and a transport reaching the wrong host
are refused).

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
- **When it polls.** An interval (60 s – 1 day) or a calendar `AutomationSchedule` — so "every
  ten minutes, check the mailbox" spends nothing until mail arrives. Failures back off
  exponentially to an hour without moving the cursor. The deadline is claimed before a poll runs,
  so a crash waits one interval instead of polling in a loop. The resident supervisor runs at most
  two polls at once beside launch supervision, from a due-time index (`source_due`).
- **Mail is the built-in source.** Mail admitted under a `wake` grant is the controller's own
  source with a fixed trigger (one coalesced inbox task per idle worker), described under Agent
  mail above; it needs no probe.

Validation: `ControllerSourcesTests` (SHA-256 vectors, output parsing, a real probe's environment,
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
- **A receipt per execution, owed from the confirmed stop.** A recipe names its transcript with
  `usage: {runtime, home, account}`. Confirming a launch stopped records it in `usage_pending` in
  the same transaction; the supervisor writes receipts beside supervision (two at a time), and
  `usage-collect` writes one by hand. Attribution — worker, task, the mail chain the execution
  acted on, the trigger whose event admitted it — comes from controller records only.
- **Finding the transcript.** Claude: `<home>/projects/*/<execution>.jsonl` plus its
  `subagents/`, exact because the recipe passes the execution id as the session id. Codex names
  its own session, so the rollout must be the only one in the launch's date folders written since
  it started whose recorded working directory is the recipe's; anything else is `unavailable`
  with the reason, never guessed.
- **Refuse, don't undercount.** An unreadable transcript makes the receipt `partial` or `failed`;
  a missing one `unavailable`. Cells are per model with five token categories, requests and cost
  (provider-reported or catalogue-priced; unpriced tokens counted separately), bounded to 16
  models with an "other models" cell that keeps totals exact.
- **Reads are O(days × cells).** Each receipt adds to `usage_daily` (day, worker, account, model)
  in its transaction; `usage-summary FROM THROUGH` pages those cells, `usage-receipts WORKER`
  pages receipts. Both go through `owner-rpc` for the Mac's Remote page and Rindabox.
- **Budgets act at admission, in budget tokens** (uncached input + cache writes + output; cached
  reads excluded because a long conversation rereads its context every turn). A worker's daily
  budget (`worker-budget-set`) stops the supervisor starting new executions for it; a mail
  grant's chain budget stops that chain's mail from waking its recipient, while still delivering
  it. Nothing running is ever stopped by a budget. Chain totals are those of executions on this
  host. A fraction-of-account-window ceiling needs usage readings this host does not take yet.

Validation: `ControllerUsageTests` (receipt idempotence and daily cells, a stop that owes nothing,
the daily budget at admission, a chain past its budget delivering without waking) and
`scripts/tests/test_controller_usage.py` (an agent under ptyd writes a Claude transcript; the
resident supervisor writes a complete, priced, attributed receipt and then holds a worker past its
budget).
