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
has been written to the inbox. The model and store do not know Sonda semantics, and unsupported
`sourceType` values are deliberately left out of daemon configuration until an adapter exists.

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

## Queue and recovery

`TriggerEngine` performs typed AND matching and decides whether a new run is immediately
`received` or held by quiet hours/concurrency. Pre-launch holds are re-evaluated at startup, after
settlement, after a source resumes, and once per minute. Only queued runs with no session or start
time may return through the opening dispatch. The assessment-to-fix handoff has its own durable
`fixQueued` state, remains active for concurrency accounting, and is resumed at that boundary after
a restart. A stage interrupted while its prompt may already have been delivered settles for
attention instead of guessing, duplicating work, or accidentally restarting assessment.

At launch, `TriggerRuntime` republishes daemon configuration, posts already-received dispatches,
then drains the daemon inbox. Later inbox notifications ingest, acknowledge and dispatch in that
order. Redelivery is safe because acceptance is durable and idempotent. One source failure cannot
stop polling another; per-source status files provide healthy, backoff and authentication-needed
receipts to the UI.

## Surfaces

The sidebar's **Triggers** destination has three pages:

- **Triggers** shows drafts, the active event kind and execution authority, and provides exact
  activation plus pause/resume controls.
- **Activity** shows durable run state and bounded results even when no session started.
- **Sources** connects the first adapter, overlays daemon health, and pauses or resumes polling.

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

Questions, phone replies and images do not need a Trigger transport. A Trigger launches an
ordinary session, so existing attention notifications, authenticated remote conversation routing
and session-owned attachments remain the continuation path. Quick push replies and source
resource fetching are later additions, not implicit v1 authority.

## Files

- `Models/TriggerModels.swift` — identities, typed events, revisions and run states
- `Core/Triggers/TriggerStore.swift` — SQLite ownership and durable idempotence
- `Core/Triggers/TriggerEngine.swift` — matching, holds, recovery and app dispatch
- `Core/Triggers/TriggerDaemonBridge.swift` — config/inbox/status/Keychain/launch-agent seams
- `Targets/TriggerDaemon/` — the polling helper and launch-agent property list
- `UI/Triggers/TriggerCenterViewController.swift` — the host-owned destination
- `UI/Windows/SessionCoordinator+Triggers.swift` — two-stage ordinary-session lifecycle
- `UI/Windows/MainWindowTriggerTools.swift` — built-in MCP application actions

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
