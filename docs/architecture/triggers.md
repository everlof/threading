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

At launch, `TriggerRuntime` republishes daemon configuration, posts already-received dispatches,
then drains the daemon inbox. Later inbox notifications ingest, acknowledge and dispatch in that
order. Redelivery is safe because acceptance is durable and idempotent. One source failure cannot
stop polling another; per-source status files provide healthy, backoff and authentication-needed
receipts to the UI.

## Surfaces

The destination has two entry points, titled apart: **All automations** (View ▸ All Automations,
the sidebar's bolt button) and a project's **<project> · Automations** (View ▸ Project
Automations, the project's row and action menu). Until 2026-10-05 both were titled
"Automations" and only the app-wide one had Sources, so a person on the project page could not
find where to approve the probe their Active automation was waiting on. Pages:

- **Automations** shows drafts, the active event kind and execution authority, and provides exact
  activation plus pause/resume controls.
- **Activity** shows durable run state and bounded results even when no session started.
- **Sources** shows the background listener's state, connects the first adapter, overlays daemon
  health, and pauses or resumes polling. Its **Probe sources** section lists probes with
  schedule, approval/health, hash prefix and the bounded diagnostic, and offers Review & Approve,
  Pause/Resume, Run now, Edit and Secrets. On a project's page it lists only the sources that
  project's event automations wait on, with the same row controls and no Connect Source or New
  Probe (a source belongs to the Mac, not to a project).
- **Remote** (app-wide only) drives an SSH host's controller.

**A source's problem is shown where its automations are.** `TriggerSourceAttention` turns a
source, its current receipt and the listener's state into at most one problem — needs approval,
changed since approval, paused, disconnected, failing, or not checked because the listener is
down — with the consequence in words and the host action that fixes it: the probe's approval
sheet, Resume, Reconnect, Login Items or a fresh registration. A project's Automations tab opens
with a **Needs attention** section of one row per such source (naming the automations that wait
on it), and an event automation's own page shows its source's row under the header. The action
opens the same flow as the Sources page; nothing approves or enables a probe on the way. The
reads are one `store.sources()` and one `TriggerSourceReceipts.read()` per page, and only when
the page has an event automation.

The destination is hosted at the pane's full width, but it draws one centred column at
`Design.Size.settingsContentWidth` plus the inset `PanelListView` keeps its rows on, installed
through the same `SettingsUI.install(page:in:top:width:)` the Settings pages use, so its ink stands
on the same edges as every Settings page. It was the 620-point readable measure until 2026-10-04,
when the page was reported as small and hard to take in: a two-line row in a narrow strip of a
wide window, and an automation's facts wrapping to a third of the room they had. At the wider
measure a row's actions stand far from its name, so every row draws a hairline under itself that
joins the two. The page tabs size to their own titles (`ThemedSegmentedControl.sizesToTitles`):
a three-choice constant for four pages drew "Activi…" under a monospaced theme. The page count
stands beside the tabs it counts, and a row's copy asks for the row the way `ControlRowView`
does, since a wrapping label has no intrinsic width to hug with and a spacer beside it broke the
detail line after two words. `TriggerCenterRenderTests` renders at a real wide pane and asserts
both measures.

The destination is retained while another page occupies the pane. On return,
`TerminalContainerViewController.showTriggers` runs `AppThemeRefresh.repaintIfNeeded` after
attachment: a theme, font or accessibility change sweeps windows and cannot reach a detached
tree. The refresh restores recorded surfaces, silhouettes and font roles without rebuilding
the page or losing its selected tab and rows. Its generation check makes an unchanged return
O(1); a missed change walks only the bounded page (25 catalogue rows or ten recent runs).
`AutomationShellRenderTests.testReturningToAutomationsRefreshesAMissedThemeChange` exercises
Settings navigation and theme installation in the shipping shell, including a dark-to-dark
switch, and captures the returned page without an extra test-owned repaint.

**An automation has a page of its own.** A row says its state in the state's ink (Active, Paused,
Draft — not active), when it runs and with what authority, and when it runs next and how it last
ran (`AutomationSummary`, one value the row and the page share). **Details** opens the page in
place: the way back, the name and state, every action as its own button — Pause/Resume or
Review & Activate, Run now, Edit…, Delete… — then the exact settings a run uses (the approval
sheet's own `AutomationReview` facts, through `FactSheetView` at the page's measure), the whole
brief, and the ten most recent runs, each with Details and, while its chat exists, Open chat. It
replaced a "Manage…" alert holding a 120-point window onto the instructions and a pop-up of three
verbs behind a Continue button. Run now on an approved revision runs on the press — the page is
the receipt and the person is acting; a draft's first run goes through the `.runNow` review, as
an agent's run request does. Delete confirms. A run's Details shows `AutomationRunReview`: result,
start and finish, changed paths and tests as facts, and the agent's summary under them.

The editor is a sheet sized from its window (up to `Layout.preferredHeight`) with one label
column and five sections — Task, When, Agent, Permissions, After a run. Only the controls the
chosen schedule reads are on it (`AutomationScheduleFields.reads…`): a daily rule shows no
weekdays, an event rule no time, and the rules field and its grammar leave when Full permission
is chosen, which shows its caution instead. A refusal stands beside Save, not at the end of a
form that may be scrolled away from it.

Account, Model and Reasoning effort are host-owned `ThemedPopUp` choices. Account discovery is
asynchronous; the model catalog and resolved default are read on one serial worker, while a
separate serial worker checks the providers' own login status (one child, ten seconds and 64 KiB
per check, a 60-second cache capped at 160 identities). Menus admit at most 32 logins, 512 models
and 32 effort levels. The account menu also observes cached usage authentication refusals;
missing usage credentials and network failures never imply logout. No probe output is retained.
Default model and effort serialize as nil. Efforts come from the selected model, or the account's
resolved default. The saved account, model and effort stay in their menus while the saved agent
is selected, even after another choice and a catalog reload: a model or effort the local catalog
does not list reads "<id> — Custom" (the catalog is a cache, so the CLI may well accept it), a
login missing from this Mac "<id> — Unavailable", and either round-trips unchanged. Changing agents
resets account/model/effort, and generation checks discard late catalog answers.

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
request file under `Poll Requests/` that the daemon consumes on its next five-second tick,
whether or not the probe is still approved by then.

**Polling.** `Targets/TriggerDaemon/TriggerProbeSources.swift` holds the pipeline and is compiled
into both the daemon and the app, so the app's tests run what the daemon runs. Per poll it checks
the hash first (a mismatch reports health `changed` and runs nothing), resolves secrets by name
from login-Keychain service `codes.threading.trigger-probe-secret` (see
[The listener](#the-listener-signature-secrets-and-health)) into the probe's environment only
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
- `Core/Triggers/TriggerDaemonBridge.swift` — config/inbox/status/launch-agent seams
- `Core/Triggers/TriggerSecretStore.swift` — writing trigger secrets with the listener's access list
- `Core/Triggers/TriggerListenerHealth.swift` — heartbeat, `launchctl print` and the listener state
- `UI/Triggers/TriggerSourceAttention.swift` — a source's problem, its words and its fix
- `Targets/TriggerDaemon/` — the polling helper and launch-agent property list;
  `TriggerProbeSources.swift` is the probe pipeline and `TriggerDaemonContract.swift` the secret
  read and heartbeat, both shared with the app
- `Core/Triggers/TriggerProbeSourceCommands.swift` — configure/approve/enable/run-now for probes
- `UI/Triggers/TriggerProbeSourceViews.swift` — probe rows, approval facts and the editor form
- `UI/Triggers/TriggerCenterViewController.swift` — the host-owned destination
- `UI/Triggers/AutomationDetail.swift` — the row/page summary, state inks, a run's receipt and the
  automation page's header
- `UI/Windows/SessionCoordinator+Triggers.swift` — two-stage ordinary-session lifecycle
- `UI/Windows/MainWindowTriggerTools.swift` — built-in MCP application actions
- `Models/AutomationPermissionPolicy.swift` — the unattended permission policy and its rule grammar
- `Core/Agent/UnattendedRunPermissions.swift` — per-session registration and the broker's decisions

## Project-owned automations

A project with saved definitions has an **Automations** navigation row with its positive count.
Empty checkouts add no row. The project action menu and View command still open the empty page.
The sidebar reads a grouped, 500-project identity/count projection on the store worker, coalesces
notifications to one in-flight query plus one pending refresh, and updates only changed project
subtrees. Paused drafts and invalid imported definitions count; deleted history does not.
It reuses `TriggerCenterViewController` with a project filter and locked project in the editor.
The global catalogue groups its bounded page by project; Remote stays global, and a project's
Sources tab lists only the sources its own event automations use.
Both destinations and the editor remain host-only: Threading owns identity, local login/source
bindings, activation, permission resolution, immutable revisions and execution truth.

`ProjectAutomation` is the independent version-1 file contract at
`.threading/automations/<id>/automation.json`. Its ID is a lowercase directory name, stable within
the project. Instructions and declared resources are relative regular files, without traversal
or symlinks. The file carries scheduling, agent/model, execution and checkout choices, permission
rules, runtime and archive behavior. It contains no project UUID, login, installation UUID,
secret or activation. Event sources are named references and are bound locally in the editor.
The existing `.threading.json` project-script contract is unchanged.

The only host substitutions are `{{project}}`, `{{workspace}}` and `{{resources}}`. They resolve
to the current checkout, its ignored local automation folder, and the verified resource snapshot.
This is explicit reference resolution, never environment or shell expansion. Portable permission
strings become validated `AutomationPermissionRule` values only after that resolution; the
approval sheet shows those exact rules and paths with the complete content fingerprint.

Trigger schema 4 stores `project_automation_binding` separately from the portable files. It maps
project/checkout/automation ID to the existing trigger identity, content fingerprint and local
login/source choices. Discovery creates paused drafts. Changed files create a new immutable draft
and remove the due schedule; invalid or missing files preserve the old record with a visible
blocking reason. Activation, run-now and dispatch re-read the files rather than depending on
a watcher. A dispatch rejected at run start gets a durable attention receipt. Worktrees
share the Git repository identity: explicit activation pauses the other checkout's schedule for
the same automation ID, and other checkouts state which checkout owns it.

`ProjectAutomationFiles` runs only on the serial `TriggerStore` background actor. Each scan
examines at most 1,000 immediate entries, materializes at most 500 definitions and admits at most
32 MiB per project. Individual files are at most 1 MiB, one definition at most 8 MiB, instructions
32 KiB and resources 32. Runtime scans eight project folders per 15-second tick; opening a project
also scans it. Hidden projects create no automation views. The catalogue builds 25 data rows per
page and history uses a database project filter plus the existing keyset cursor. The local binding
owns the trigger's complete history after adoption, including earlier frozen revisions. Deleted
bindings remain indexed tombstones and do not fill the bounded live catalogue or ownership scan.

Save is shared by the editor and `manage_automation`: it validates the expected revision and
fingerprint, prepares a bounded complete directory, and atomically swaps it with `renameatx_np`.
A cooperating-writer lock in the ignored local folder and a final fingerprint check reject stale saves. Undeclared authored
files are retained within a separate 128-entry/8-MiB write bound. No staging or commit happens.
Existing database-only automations retain their local storage and are labelled accordingly.

The ignored `.threading/local/automations/<id>/` contains state, reports, data and verified
`revisions/<fingerprint>/` snapshots. A run reads the snapshot reviewed for its revision, so
an outside edit pauses future work without changing a running task's scripts. A damaged local
snapshot blocks execution too. `.threading/.gitignore` ignores `/local/`.

`automationWorkspace` is available only for project-owned direct tasks. `ScheduledSessionPlan`
and `AgentSession.automationWorkspace` persist the explicit connection, and central
`workingDirectory(in:)` routes launches and resumes there while logical project ownership stays
with the original project. This is not a Git worktree. A dirty product checkout is allowed;
ordinary edit-capable checkout/worktree runs retain their previous policy. Checkout following,
manual checkout moves and product Git turn checkpoints exclude these sessions.

Restoring Git discovers the definitions again as drafts. Local account/source mapping must be
reviewed and activated on the new host. History, sent receipts, processing windows, reports and
other local state return only from their separate backups. The Sonda move is explicit adoption
of its existing trigger identity, left paused; no general migration UI or remote-controller
format change is introduced.

## The listener: signature, secrets and health

**`threading-triggerd` carries no entitlement.** From 2026-09-12 to 2026-10-05 it carried
`keychain-access-groups` so it could read source credentials and probe secrets from a shared
group, and it never ran: the key is profile-backed, AMFI honours it only when an embedded
provisioning profile authorizes it, and a bare executable in `Contents/Helpers` cannot embed one.
launchd's every spawn ended in `OS_REASON_CODESIGNING` ("Code has restricted entitlements, but the
validation of its code signature failed"), more than 150 times by the evening it was found, while `codesign --verify`
passed and ServiceManagement reported the job enabled. A profiled export did not help, since the
profile is embedded in the app, not the helper. `check_bundle_entitlements.py` now refuses any
profile-backed key on a bundled helper. Shipping the helper as a bundle with its own profile was
the alternative; it needs a second App ID and Developer ID profile that do not exist, a new
export mapping and LoginItems registration, all of it provable only on a signed release, for a
capability the login Keychain already provides.

**Secrets are login-Keychain items whose access list names the app and the listener.** The access
group never held them anyway: `kSecAttrAccessGroup` without `kSecUseDataProtectionKeychain` lands
in the login Keychain with an access list naming only the creating app (measured with a
profile-signed bundle). `TriggerSecretStore` (app) replaces an item rather than updating it, so its
`SecAccess` trusts this app and `Contents/Helpers/threading-triggerd`, each by designated
requirement (identifier, Apple anchor, team), and marks it with `kSecAttrGeneric`
`threading-triggerd-acl/1`. `TriggerSecretKeychain.read` (`TriggerDaemonContract.swift`, shared)
is the listener's only read: login Keychain, no access group. The daemon switches Keychain user
interaction off for its process, so an item it may not read answers `errSecAuthFailed` and the
source reports authentication required with the secret's name, never a dialog from a background
helper. Measured on 2026-10-05 with Developer ID–signed binaries: the trusted helper read without
a prompt, a rebuilt helper with the same requirement still did, and an untrusted same-team
binary was refused. Another process running as the person can overwrite an item's value (the
encrypt authorization is open), as it can rewrite `sources.json`; it cannot read one.

At every launch `TriggerRuntime` rewrites, on a detached worker, every item without the marker:
the app is on those items' lists, so it reads each value without a prompt and stores it again with
the listener's access. The whole pass runs with keychain interaction switched off through
`KeychainInteractionGate`, the app's one owner of that process-global switch (the Claude usage
reader goes through it too, so neither can undo the other's setting). An item it cannot read
silently (one stored by a differently signed Debug build, or any item while the keychain is
locked) is counted and left alone, never put in front of the person and never re-signed for this
build; the listener names it as one to set again, and the next launch retries it. Once every item
carries the marker a pass is one attribute query per service. Automated runs never migrate. The app keeps
its own `TEAM.codes.threading.triggers` entitlement: it is the default access group of every
protected item the app already stores, and the auto-installer's credential-realm check reads it.

Because the identities are designated requirements, a Debug build (Apple Development) and a
Developer ID build cannot read each other's items; signed launch and sharing are still provable
only on a Developer ID build (`scripts/release.sh` or the profiled auto-install).

**Health says whether the listener runs, not whether it is registered.** The daemon writes
`listener.json` (pid, start, beat) every 30 seconds. `TriggerSourceReceipts.read()` reads the
status files, the SMAppService status and the heartbeat on a worker, and runs one bounded
`launchctl print gui/<uid>/codes.threading.triggerd` (2 s, 64 KiB) only when the heartbeat is
missing or older than 120 s. `TriggerListenerState.classify` is pure: a fresh beat is running;
launchd's `last exit reason` or `job state = spawn failed` with no pid is **refused** (the reason
is shown verbatim); a pid without a beat is a listener from before heartbeats; a stale beat or an
exit code is **stopped**; plus requires-approval, not-registered and missing-helper. The app
unregisters the listener when `sources.json` gives it nothing to do
(`TriggerDaemonConfiguration.needsListener`: no connected source, enabled probe or schedule), so
not-registered with nothing needed is **idle** ("Off", no repair offered) rather than a failure;
an unreadable configuration counts as needed, so a real failure is never explained away. The Sources
page's listener row shows the state, its reason and the fix (Open Login Items…, Restart Listener —
not offered for a refusal, which only a different build fixes), and while the listener is down an
enabled source reads **Not checked** instead of its last receipt or a perpetual "Checking".
`list_trigger_sources` returns `background_listener` (`running`, `starting`, `refused`,
`stopped`, `requires_approval`, `not_registered`, `idle`, `missing_helper`) with
`background_listener_detail`, and each source's `health` is `not_checked` with the listener's
reason in `diagnostic` while it is down.

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
