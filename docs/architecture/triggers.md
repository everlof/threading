# Triggers

Triggers are Threading's provider-neutral `listen → match → start an agent` feature. A source
reports bounded facts; an immutable trigger revision supplies the project, instructions and
authority. Event content is never executable configuration.

## Ownership

The app is the sole owner of `triggers.db` and of every session launch. `TriggerStore` keeps
source installations, trigger definitions, immutable revisions, accepted events and run
receipts in its own SQLite database. Event and run creation commit atomically, with uniqueness at
both the source-event key and `(trigger, revision, event)` run key.

`threading-triggerd` is a separate per-user launch agent. It owns only source polling, provider
cursors, backoff, a bounded file inbox and health receipts. It never opens `triggers.db`, matches
rules, chooses projects, reads repository files or starts an agent itself. The app publishes a
credential-free source configuration, the daemon writes normalized `TriggerEvent` envelopes,
and a distributed notification asks the app to drain them. If Threading is not running, the
daemon opens it without activation and repeats the notification.

The first adapter is Sonda's read-only review-required feed. Its stable case ID and review cycle
become the event identity and revision; its cursor is committed only after every returned event
has been written to the inbox. It is a built-in source on the probe contract: the daemon fetches
the page over HTTPS with the Keychain credential, `SondaFeedAdapter` (in the shared
`TriggerProbeSources.swift`) validates it and turns it into a `TriggerSourceReport`, and the same
`TriggerProbeSourceRunner.deliver` stage a probe uses writes the events and then commits the
cursor. Everything observable is what the compiled-in adapter wrote — event kind
`case.review-required`, attributes, title, portal deep link, inbox files named by feed cursor, the
integer `cursors.json`, and health (an HTTP 401/403 or missing credential is authentication
required; any other failure, including an inbox write, backs off exponentially to five minutes). The model and store do not know Sonda semantics, and unsupported
`sourceType` values are deliberately left out of daemon configuration until an adapter exists.
The second source type is `probe`: a person's own program on the portable probe contract, below.

## Authority

Activation names one exact immutable `TriggerRevision`. Agents may inspect sources and triggers,
create or edit paused drafts, and ask for that revision to be enabled or run through the built-in
MCP tools. Only a host approval sheet showing that revision lets it start work: an agent's report
that the user wanted it is not the authority, because a conversation can be steered by content it
read. Credentials are entered only in the Sources UI, stored in Keychain, and never returned
through MCP or placed in prompts.

Every run has two possible stages:

1. Assessment starts in the provider's native conversation surface with Plan/read-only
   permission. The opening prompt separates host instructions from untrusted event evidence.
2. A `straightforwardFix` result may start a second turn only when the activated revision already
   grants `assessThenFix`. Threading changes that same session to local edit permission, verifies
   an existing checkout is clean or uses an isolated managed worktree, and sends a host-authored
   fix prompt.

A run is settled as unreported on the first runtime edge where its session stops owing an
outcome, so that edge must be the prompt's own turn ending or the process exiting. Two readiness
signals that ended the opening turn early are documented under "`system/init` is not a turn
boundary" in [`native-conversations.md`](native-conversations.md).

The grant ends at local edits and tests. Trigger runs cannot push, deploy, open a change request,
write back to the source or acquire a source resource. Those remain separate future authorities.
The configured maximum runtime is armed as the session's curfew across both stages.

### Unattended permissions

A permission card in a chat nobody watches protects nothing: it stops the run until its curfew.
That happened on 2026-10-03, when a scheduled run's allow-listed `collect.py` waited for a click
for its whole hour. So an unattended run never raises one. The revision carries an
`AutomationPermissionPolicy` (`Models/AutomationPermissionPolicy.swift`), which the person
approves on the sheet with everything else:

- **Allow-list** (the default, and the meaning of every revision saved before policies existed):
  Threading's read-only allowances, local edits inside the run's own folder when its mode allows
  edits, and exactly the listed rules. The grammar is Claude's spelling, kept small and validated
  when the revision is saved: `Bash(command)` / `Bash(command *)` for one simple command,
  `Write(/abs/glob)` or `Edit(…)`, `WebFetch(domain:host)` and `mcp__server__tool`. A rule that is
  not understood is refused, never guessed at; `Read(…)` is refused as unnecessary.
- **Full permission**: every call of a stage that may edit runs without asking. Refused for
  read-only modes, and an assessment stage before a fix still gets read-only answers. The stage
  launches in its ordinary mode (`acceptEdits`): every Claude tool call reaches the broker's
  `PreToolUse` hook, whose answer is final. Codex sandbox limits that raise no approval request
  still apply.

`UnattendedRunPermissions` holds the policy per session. `TriggerStore.claimDispatch` registers it
when it reserves the run's session, before anything is launched there; a fix stage recovered
after a relaunch registers again where `TriggerRuntime` publishes it. It is dropped once the store
reports the run is no longer active, so a person who keeps working in that chat gets the ordinary
cards back. `PermissionBroker.decide` asks it before anything else and answers at once:
allowed with the rule and revision named, or denied with a reason the agent can act on. A command
line is split the way `ShellCommandPolicy` splits it, and every segment must be read-only or match
a rule, so a chain cannot carry a second command past a rule naming the first; redirection,
substitution and backgrounding are refused outright. A call that would raise a macOS permission
prompt is refused even under full permission, because nobody is there to answer the dialog.

The authority is the approved revision, never the project folder: `.claude/settings*.json` can be
checked into a repository, and letting it decide would let a clone widen what an approved
automation may do without the sheet ever showing it.

## Queue and recovery

`TriggerEngine` performs typed AND matching and decides whether a new run is immediately
`received` or held by quiet hours/concurrency. Pre-launch holds are re-evaluated at startup, after
settlement, after a source resumes, and once per minute. Only queued runs with no session or start
time may return through the opening dispatch. The assessment-to-fix handoff has its own durable
`fixQueued` state, remains active for concurrency accounting, and is resumed at that boundary after
a restart. A stage interrupted while its prompt may already have been delivered settles for
attention instead of guessing, duplicating work, or accidentally restarting assessment.

**Release is per trigger, never a global window.** The queue used to read the 100 oldest held runs
and skip the ones still held, so a burst behind one trigger's concurrency limit (or a run of a
superseded revision) filled the window and stopped every other trigger's run behind it.
`TriggerStore.queueReleaseCandidates()` now returns one row per trigger that can take work: enabled
at its held runs' revision with no pending draft, source enabled, and its active count below the
revision's `maximumConcurrentRuns`, which SQL compares against the revision's own JSON limit. The
engine drops candidates inside quiet hours, then takes at most each trigger's free slots, oldest
first through `trigger_run_trigger_state`, up to 100 per release. The cost is one indexed row per
live definition (the catalogue's 500 bound) plus the runs actually released; a trigger at its limit
costs one row however deep its queue. `TriggerQueueFairnessTests` holds a 150-run burst on one
trigger with `maximumConcurrentRuns = 1` and requires another trigger's run to release on the
next pass.

**A held run whose authority is gone settles instead of waiting.** Saving an edit (the draft
`claimDispatch` would refuse it for), activating a different revision, deleting the automation and
deleting its source each settle that trigger's held, never-started runs as `suppressed`, in the same
transaction and with a diagnostic naming the reason (`QueuedRunSettlement`), which Activity shows as
the receipt. The work is the stranded runs, found through `trigger_run_trigger_state` or, for a
source, `trigger_revision_source_kind`. Pausing an automation or a source is not such a change: its
held runs stay and are released on resume. Receipts stranded before this rule existed are settled
once at launch by `settleStaleQueuedRuns`, a rowid-cursored pass over held runs.

At launch, `TriggerRuntime` republishes daemon configuration, posts already-received dispatches,
then drains the daemon inbox. Later inbox notifications ingest, acknowledge and dispatch in that
order, a page of 100 files at a time until a page comes back short. Redelivery is safe because
acceptance is durable and idempotent. A file that does not decode as a `TriggerEvent`, or that the
store refuses on its bounds, is moved to `Inbox/Quarantine/` and the drain continues: one such file
used to fail the whole read, so every event behind it waited for good. The quarantine keeps the 64
newest files and evicts older ones; each move writes a `triggers` record to `EventLog` with the
reason and byte count, never the content. A failure that could succeed later — the store itself,
or a file that cannot be read — stops the drain and leaves the file for the next one. One source
failure cannot stop polling another; per-source status files provide healthy, backoff and
authentication-needed receipts to the UI.

## Surfaces

The sidebar's **Triggers** destination has three pages:

- **Triggers** shows drafts, the active event kind and execution authority, and provides exact
  activation plus pause/resume controls.
- **Activity** shows durable run state and bounded results even when no session started.
- **Sources** connects the first adapter, overlays daemon health, and pauses or resumes polling.
  Its **Probe sources** section lists probes with schedule, approval/health, hash prefix and the
  bounded diagnostic, and offers Review & Approve, Pause/Resume, Run now, Edit and Secrets.

The destination is hosted at the pane's full width, but it draws one centred column at
`Design.Size.readableWidth` plus the inset `PanelListView` keeps its rows on, installed through
the same `SettingsUI.install(page:in:top:width:)` the Settings pages use. It is the display
panel's list vocabulary — a name, a detail line, an action just beyond the copy — and given a
whole wide window it stopped reading as one: the three page tabs stretched across the window
because `ThemedSegmentedControl` states `noIntrinsicMetric`, the count sat alone in the opposite
corner, and a row's button stood a thousand points from the name it acts on. The page count now
stands beside the tabs it counts, and a row's copy asks for the row the way `ControlRowView`
does, since a wrapping label has no intrinsic width to hug with and a spacer beside it broke the
detail line after two words. `TriggerCenterRenderTests` renders at a real wide pane and asserts
both measures, because none of this was visible at the fixture width that shipped.

Opening the destination clears the project sidebar's selection (`setTriggersMode(true)` calls
`clearSelection()`). The page belongs to no row, and a session left highlighted beside it was
worse than a wrong picture: `NSOutlineView` posts no selection change for a click on the row
already selected, so clicking that session to go back did nothing. Back still returns to it,
because history replays the sidebar's own `select`.

This destination and its approval sheets are host-only security surfaces. Extensions may observe
only future explicitly published facts; they cannot replace credentials, authority or run-state
presentation. The built-in MCP tools are the supported agent automation seam: three lists,
disabled draft creation, host-approved activation, `manage_automation` (whose enable and run are
host-approved the same way), and session-bound assessment/final reporting.

**A failed run reaches the person; a successful one waits for them.** `TriggerRunAlerts` is the
one owner of that decision. A run that settles `failed` or `needsAttention` alerts the Mac
(`AttentionAlertCenter`, with its master switch and per-session mute) and, when Remote Access is
on, the paired iPhone through the requested-notification route and its opt-in. It does so once
per run, keyed by run id, however many edges observe the settlement. A completed run alerts
neither: its receipt is the in-app toast and Activity. The phone half needs a session, because
every remote notification event is scoped to one, so a run refused before its session started
reaches the Mac only (`postAppUpdate`). The alert carries the real reason. Where the provider
refused the turn in a typed field, `TriggerRunDiagnostic` names it instead of "ended without
reporting a result": Claude's `stream-json` marks a rejected login with
`"error":"authentication_failed","is_api_error_message":true` on a synthetic assistant line
(measured against CLI 2.1.288; `AgentTurnFailure`), and the run then says which login is no longer
signed in, with the one-year token offered only where the runtime accepts one. This was added
after a scheduled run failed on an expired login on 2026-10-03 and the person found out by looking.

Questions, phone replies and images do not need a Trigger transport. A Trigger launches an
ordinary session, so existing attention notifications, authenticated remote conversation routing
and session-owned attachments remain the continuation path. Quick push replies and source
resource fetching are later additions, not implicit v1 authority.

## Probe sources

A `probe` source is an executable a person (or, as a draft, an agent) wrote, run by the daemon on
the same `TriggerProbe` contract the controller uses
([portable-trigger-sources.md](../feature-drafts/portable-trigger-sources.md)): exact argv, no
inherited environment, `{cursor, limit}` on stdin, event lines then one cursor line, exit 75/77 for
backoff/authentication, host-enforced timeout, output and event caps. Its record is
`TriggerSourceInstallation.probe`: the controller's own `ControllerSourceSpec`, a revision for
compare-and-swap edits, the SHA-256 of the executable and script when configured, and the hash a
person approved. No schema migration: the field rides in the source's JSON payload.

**Authority.** `TriggerProbeSourceCommands.configure` — the Sources editor and the agent's
`manage_automation draftSource` alike — always writes the source paused with approval cleared.
Only `approve`, called after the host sheet showed the exact paths, full hash, schedule,
arguments, environment keys, secret names and an explicit unsandboxed warning, records the
approval, and only for the hash still on disk. `TriggerStore` refuses to save an enabled probe
whose current hash is unapproved, whichever path writes. One Mac rule beyond the controller's
validation: a configured script must be the first argument, so the hashed script is the one the
executable runs. No tool, extension or theme seam approves or enables a probe.

**Projection.** `TriggerDaemonConfigurationStore.configuration(for:)` (pure, tested) adds
`probes` to `sources.json` — approved probes only, paused ones included so **Run now** can poll
them. The schema version stays 1; an older reader ignores the field. Run now writes an empty
request file under `Poll Requests/`. The daemon removes it only once its poll has been claimed,
or once it never can be because the probe is no longer in a readable configuration (so a request
for a deleted or unapproved probe cannot run under a later approval). A request that finds both
poll slots busy, or that probe already polling, stays for a later tick: the daemon used to delete
every request before claiming, and a busy tick dropped it. `TriggerProbeClaimPolicy` and
`TriggerProbePollRequests` live in the shared file, so `TriggerDaemonDeliveryTests` runs the
daemon's rule.

**Polling.** `Targets/TriggerDaemon/TriggerProbeSources.swift` holds the pipeline and is compiled
into both the daemon and the app, so the app's tests run what the daemon runs. Per poll it checks
the hash first (a mismatch reports health `changed` and runs nothing), resolves secrets by name
from Keychain service `codes.threading.trigger-probe-secret` into the probe's environment only
(and redacts their values from the diagnostic), runs the probe, writes each event to the inbox,
and only then commits the cursor (`probe-cursors.json`); a failure between them redelivers and
acceptance is idempotent. The probe loop is independent of the Sonda long-poll: each five-second
tick claims manual requests first, then at most eight due probes, with at most two polls in
flight and one per source, so a hanging probe cannot delay another past its own timeout.
Deadlines persist in `probe-schedule.json`; failures back off exponentially from the interval to
an hour, as the controller's do. Each probe has a private `0700` working directory under
`Probes/`.

**Deleting** a probe (`TriggerProbeSourceCommands.delete`, host-only, confirmed on the page)
writes a tombstone: `probe.deletedAt`, approval cleared, paused. It leaves the daemon's
configuration, so polling stops on the next tick; it disappears from the Sources page, the
automation editor's source list and `list_trigger_sources`; configure, approve, enable and Run now
refuse it. The record, its accepted events and their run receipts stay, so Activity keeps naming
the source. No agent tool deletes a source.

**Timing.** The editor states timing with the automation editor's own schedule controls,
`AutomationScheduleFields`, which both editors now use. "Fixed interval" becomes the spec's
`intervalSeconds`; daily, selected weekdays and weekly become its calendar `schedule` (validated,
with an explicit IANA zone), which the daemon follows with `AutomationSchedule.next(after:)`.

**Events.** A probe event becomes an ordinary `TriggerEvent` of kind `probe.event`: its id and
revision are the identity, its typed fields become typed attributes (integral numbers as
`integer`, others `decimal`, booleans, strings), a `title` or `subject` field titles it, and
`evidence` travels in `TriggerEvent.evidence` — never an attribute, so no condition matches on it —
inside the prompt's untrusted-evidence block. `TriggerEngine` matching, immutable revisions and
two-stage authority apply unchanged.

**Why the daemon compiles shared files rather than linking the packages.** Linking
`ThreadingController` into `threading-triggerd` made Xcode build `ThreadingDomain` as a dynamic
package framework (the test bundle links it too) that both helper tools copy to
`Products/Frameworks`, which fails build-for-testing with "Multiple commands produce". The daemon
therefore compiles `TriggerProbe.swift` and `AutomationSchedule.swift` (both Foundation-only)
directly, and the shared file's package imports are behind `THREADING_TRIGGER_DAEMON`, with the
daemon reading the spec's run fields as `TriggerProbeRunSpec` (same JSON shape).

## Files

- `Models/TriggerModels.swift` — identities, typed events, revisions and run states
- `Core/Triggers/TriggerStore.swift` — SQLite ownership and durable idempotence
- `Core/Triggers/TriggerEngine.swift` — matching, holds, recovery and app dispatch
- `Core/Triggers/TriggerDaemonBridge.swift` — config/inbox/status/Keychain/launch-agent seams
- `Targets/TriggerDaemon/` — the polling helper and launch-agent property list;
  `TriggerProbeSources.swift` is the probe pipeline shared with the app
- `Core/Triggers/TriggerProbeSourceCommands.swift` — configure/approve/enable/run-now for probes
- `UI/Triggers/TriggerProbeSourceViews.swift` — probe rows, approval facts and the editor form
- `UI/Triggers/TriggerCenterViewController.swift` — the host-owned destination
- `UI/Windows/SessionCoordinator+Triggers.swift` — two-stage ordinary-session lifecycle
- `UI/Windows/MainWindowTriggerTools.swift` — built-in MCP application actions
- `Models/AutomationPermissionPolicy.swift` — the unattended permission policy and its rule grammar
- `Core/Agent/UnattendedRunPermissions.swift` — per-session registration and the broker's decisions

The cross-process Keychain access group is a signed-Release contract. Unsigned/ad-hoc Debug builds
can compile and render the feature but cannot prove ServiceManagement registration or credential
sharing; validate those two behaviors on a signed build.

**A locally auto-installed build is not that build either.** `keychain-access-groups` is
profile-backed, and the auto-installer deliberately names no provisioning profile, so it derives
the app's and the daemon's entitlement files with the group removed — the build the developer runs
all day therefore cannot read a source credential across the process boundary, and
`TriggerSourceCredentialStore` asks for a group it does not have. Credential sharing is provable
only on a profile-signed release from `scripts/release.sh`. The release path carries the group
without any change: the Developer ID profile's entitlements dict already lists it. See
[`releasing.md`](releasing.md#keeping-applications-on-master) — the first version of
this entitlement broke the auto-install loop for three days because the derivation matched only
`com.apple.developer.*`.

## Recurring automations and controller ownership

The destination is **Automations**. Event rules retain their existing immutable revisions and
assess/fix behavior. A revision may instead have `AutomationOptions.schedule`, and the task modes
`taskReadOnly` and `taskLocalEdits` run saved instructions directly. The local-edit mode checks an
existing checkout for cleanliness or uses the managed-worktree path. A currently executing automated conversation
cannot use the management tool to alter automations.

Calendar/interval arithmetic is `ThreadingDomain.AutomationSchedule`, shared with the portable
controller. Daily, selected weekdays, weekly and anchored intervals use an explicit IANA zone.
Calendar rules choose the first repeated DST hour and advance a nonexistent hour within its day;
intervals advance from the saved anchor, never from the previous execution's finishing time.
The next calendar occurrence is searched from the start of a local day, never from the moment a
run fired: `Calendar.nextDate(after:)` called from inside a repeated hour returns that hour's
second copy even under `.first`, which ran a 02:30 schedule twice on the fall-back night. An
anchor is kept to whole seconds, which is all its wire form carries.

The Mac owns its local `automation_due` index in trigger schema v3. Each sweep reads at most 32
due definitions; each one's reservation, occurrence identity and next deadline commit together in
their own transaction, so a rule that cannot be admitted is retried five minutes later instead of
failing every schedule in the sweep. More than 90 seconds late is missed: `skip` records a
suppressed receipt, while `latest` admits one run, labelled with the most recent occurrence it
stands for, and advances directly past now. An active previous run suppresses the occurrence instead of building
an unbounded queue. Reporting a final result enters `finishing`, which still occupies the slot;
the provider's authoritative turn-end edge settles it. Process exit without that proof remains an
attention state. Manual run requests require a stable request key and reuse their receipt. An explicit run can
exercise a saved draft without enabling its schedule. Its authority is a host-authored run field,
never inferred from a source-controlled event ID. Only a source event may wait in the queue when
its session cannot start: the queue re-offers it while its trigger and source stay active. A
schedule occurrence or an explicit run has no such path, and starting it later would be the
backlog a schedule promises never to build, so it settles as needing attention instead.

The daemon configuration includes the next local schedule deadline. The existing listener can
wake Threading when it arrives, while the Mac is awake and logged in. A source with no credentials
is not invented for the local clock. The Mac remains the local execution owner. Sleep and missed
moments follow the saved policy; the daemon does not claim to wake a sleeping machine. The file is
a projection rewritten after every committed change, and failing to write it is logged rather
than thrown: an error there once reported a saved configuration as failed (inviting a duplicate)
and dropped the dispatches a sweep had just reserved.

`archiveOnSuccess` requests the ordinary archive scheduler only after a successful final report
and an authoritative transition back to a ready prompt. A process exit or blocker keeps the run
visible. The automation request rechecks prompt readiness during the grace period and at firing;
new work or a question cancels it. Failed and needs-human results never request archive.
The durable run and result remain in Activity. Deleting a definition clears its editable/active
pointers and stops scheduling while retaining immutable revisions and receipts.

`manage_automation` and the editor call `AutomationCommands`, with complete replacement values
and expected revision checks for edits. The tool covers hosts/workers/list/get/configure/enable/pause/delete/run
and runs, with bounded catalogue and history pages. Its `enable` and `run`, local or remote, wait
for the same host approval sheet as Activate, showing the exact revision (or the controller's
current spec); without a window to show it they are refused. The host UI's own buttons pass no
approver because the person is already acting. Credential entry remains outside
agent tools. The editor and connection controls are deliberately host-only: Threading owns
identity, permissions, revisions, routing and run truth under every theme.

The **Remote** page sends those operations to the controller on an existing SSH host, with explicit
absolute executable and database paths, saved on the host record once a connection succeeds. The
agent tool names only the host and always uses those saved paths; it cannot choose which program
the Mac runs over the person's SSH identity. Remote enable, run and delete confirm on the page too.
`owner-rpc` is the transport; no shell interpolation of
instructions and no copying of the remote database occurs. The VPS owns its schedules, worker
queue and history, independently of the Mac. The controller must already be installed and its
supervisor running; connecting does not install, configure a worker recipe, or start a service.
See [autonomous-controller.md](autonomous-controller.md) for that separate execution boundary.

Scaling contract: typical 5–20 definitions, stress 500 local definitions; the local catalogue has
that explicit creation limit. The UI constructs at most 25 local rows per page, coalesces store-change bursts, and reads
activity through a 25-row keyset cursor. Agent reads return bounded pages. Remote controller queries use
cursor/byte bounds and indexed due reads, with eight due records per supervisor tick; SSH captures
at most 2 MiB and has one in-flight automation request. History does not participate in clock
scans. Tests cover DST, restart/deduplication, overlap, stale configuration, retained history, and
controller delivery-aware archive eligibility.

Verification (2026-09-30): 37 focused Mac tests passed, including the shipping-window renders in
System, Pure and Neo Brutalism. The final 500-definition fixture prepared its records in
2.282 s and projected, mounted and laid out one page in 126.5 ms (including actor reads), retaining
27 list views: one heading, 25 rows and navigation. This is an interaction measurement, not an
isolated main-thread frame duration. The controller passed 26 core tests and its CLI/owner-RPC
lifecycle on macOS and Linux. Eleven real-PTY controller tests include a due schedule running
through the resident supervisor without a Mac client, final result visibility, and restart without
duplicate work. The shipping create/save/relaunch UI journey also passed, with inspected captures of the editor,
schedule/archive controls and restored paused task. These are disposable fixtures; no production
VPS was deployed or configured.
